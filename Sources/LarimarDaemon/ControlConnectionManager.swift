import Foundation
import LarimarShared
import OSLog

/// Manages control connections: for each allowed host, a pre-step that
/// prepares the remote socket directory followed by `ssh -N -R` forwarding
/// the remote control socket to the host's Mac-side socket.
@MainActor
final class ControlConnectionManager: ObservableObject {
    @Published private(set) var connections: [String: ControlConnection] = [:]

    private var sshAuthSock: String?
    private var isShuttingDown = false

    static let prepTimeout: TimeInterval = 15

    struct ControlConnection {
        let identity: ControlHostIdentity
        /// nil when the Mac-side socket could not be set up; the host is unusable.
        let macSocketPath: String?
        var status: ControlStatus = .stopped
        var errorMessage: String?
        var retryCount = 0
        var retryTask: Task<Void, Never>?
        /// Changes on every attempt; late callbacks from older attempts are ignored.
        var attemptToken = UUID()
        /// The pre-step or the forwarding ssh; they never run at the same time.
        var process: Process?
        var prepTimeoutTask: Task<Void, Never>?
        var connectedSince: Date?

        var name: String { identity.name }

        mutating func resetRetry() {
            retryTask?.cancel()
            retryTask = nil
            retryCount = 0
        }

        mutating func clearProcess() {
            prepTimeoutTask?.cancel()
            prepTimeoutTask = nil
            process = nil
            connectedSince = nil
        }
    }

    func updateAuthSock(_ sock: String?) {
        sshAuthSock = sock
    }

    // MARK: - Lifecycle

    func add(identity: ControlHostIdentity, macSocketPath: String, autoConnect: Bool) {
        guard !isShuttingDown else { return }
        remove(name: identity.name)
        connections[identity.name] = ControlConnection(identity: identity, macSocketPath: macSocketPath)
        if autoConnect {
            connect(name: identity.name)
        }
    }

    /// Mark a host as unusable without a connection attempt (e.g. its Mac socket failed).
    func addFailed(identity: ControlHostIdentity, message: String) {
        remove(name: identity.name)
        connections[identity.name] = ControlConnection(identity: identity, macSocketPath: nil, status: .error, errorMessage: message)
    }

    func remove(name: String) {
        guard connections[name] != nil else { return }
        disconnect(name: name)
        connections.removeValue(forKey: name)
    }

    func connect(name: String) {
        guard !isShuttingDown, var connection = connections[name] else { return }
        guard !connection.status.isActive, connection.macSocketPath != nil else { return }

        connection.resetRetry()
        connection.errorMessage = nil
        startAttempt(connection)
    }

    func disconnect(name: String) {
        guard var connection = connections[name] else { return }
        connection.resetRetry()
        connection.attemptToken = UUID()
        if let process = connection.process, process.isRunning {
            Log.control.info("Disconnecting control connection \(name, privacy: .private(mask: .hash))")
            process.terminate()
        }
        connection.clearProcess()
        // An unusable host keeps its error row
        if connection.macSocketPath != nil {
            connection.status = .stopped
            connection.errorMessage = nil
        }
        connections[name] = connection
    }

    func shutdown() {
        isShuttingDown = true
        for name in connections.keys {
            disconnect(name: name)
        }
    }

    func retryAllReconnecting() {
        guard !isShuttingDown else { return }
        for var connection in connections.values where connection.status == .reconnecting {
            connection.resetRetry()
            startAttempt(connection)
        }
    }

    func resetStableRetryCounters() {
        let now = Date()
        // Skip no-op writes: every assignment publishes and re-renders the menu
        for (name, connection) in connections where connection.retryCount != 0 {
            if connection.status == .connected,
               let since = connection.connectedSince,
               now.timeIntervalSince(since) > ReconnectBackoff.stableAfter {
                connections[name]?.retryCount = 0
            }
        }
    }

    func controlInfos() -> [ControlInfo] {
        connections.values
            .map { ControlInfo(name: $0.name, sshHost: $0.identity.sshHost, status: $0.status, errorMessage: $0.errorMessage) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Attempt
    // Each step mutates a local copy and stores it once, so one transition publishes once.

    private func startAttempt(_ connection: ControlConnection) {
        guard !isShuttingDown else { return }
        var connection = connection
        let name = connection.name
        let token = UUID()
        connection.attemptToken = token
        connection.status = .preparing

        let process = makeSSHProcess(arguments: SSHCommand.prepArguments(identity: connection.identity))
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { [weak self] proc in
            // Output is tiny (a path or a short error), so reading after exit is safe
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                self?.prepFinished(name: name, token: token, process: proc, stdout: out, stderr: err)
            }
        }

        do {
            try process.run()
            ChildProcessRegistry.shared.register(process)
            // ssh may exit before reading stdin; avoid SIGPIPE and ignore write errors
            let writeFd = stdin.fileHandleForWriting.fileDescriptor
            _ = fcntl(writeFd, F_SETNOSIGPIPE, 1)
            let script = Array(ControlPaths.remotePrepScript.utf8)
            _ = script.withUnsafeBytes { write(writeFd, $0.baseAddress, $0.count) }
            try? stdin.fileHandleForWriting.close()
        } catch {
            Log.control.error("Failed to spawn control pre-step for \(name, privacy: .private(mask: .hash)): \(error, privacy: .private)")
            fail(connection, message: "Failed to run ssh: \(error.localizedDescription)", retry: false)
            return
        }

        connection.process = process
        // Deadline: terminate, then kill if it still lingers. Cancelled as soon as the pre-step ends.
        connection.prepTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.prepTimeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return }
            Log.control.notice("Control pre-step timed out for \(name, privacy: .private(mask: .hash))")
            process.terminate()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        connections[name] = connection
    }

    private func prepFinished(name: String, token: UUID, process: Process, stdout: Data, stderr: Data) {
        guard !isShuttingDown, var connection = connections[name], connection.attemptToken == token else { return }
        connection.clearProcess()

        let exitCode = process.terminationStatus
        guard process.terminationReason == .exit, exitCode == 0 else {
            let message = SSHCommand.errorMessage(stderr: stderr) ?? "Remote pre-step failed (exit \(exitCode))"
            Log.control.error("Control pre-step failed for \(name, privacy: .private(mask: .hash)), exit=\(exitCode)")
            let permanent = process.terminationReason == .exit && ControlPaths.permanentPrepExitCodes.contains(exitCode)
            fail(connection, message: message, retry: !permanent)
            return
        }

        let output = String(data: stdout, encoding: .utf8) ?? ""
        guard let remoteSocket = ControlPaths.remoteSocketPath(fromPrepOutput: output) else {
            Log.control.error("Unsupported remote socket path for \(name, privacy: .private(mask: .hash))")
            fail(connection, message: "Unsupported remote path (allowed: A-Z a-z 0-9 . _ / + -, max 103 bytes)", retry: false)
            return
        }

        spawnControlSSH(connection, remoteSocket: remoteSocket)
    }

    private func spawnControlSSH(_ connection: ControlConnection, remoteSocket: String) {
        guard let macSocket = connection.macSocketPath else { return }
        var connection = connection
        let name = connection.name
        let token = connection.attemptToken
        connection.status = .connecting

        let process = makeSSHProcess(arguments: SSHCommand.controlArguments(
            identity: connection.identity,
            remoteSocket: remoteSocket,
            macSocket: macSocket
        ))
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        SSHCommand.watchReady(stdout: stdout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, var current = self.connections[name], current.attemptToken == token,
                      current.status == .connecting, process.isRunning else { return }
                current.status = .connected
                current.errorMessage = nil
                current.connectedSince = Date()
                self.connections[name] = current
            }
        }

        process.terminationHandler = { [weak self] proc in
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                self?.controlSSHFinished(name: name, token: token, process: proc, stderr: err)
            }
        }

        do {
            try process.run()
        } catch {
            fail(connection, message: "Failed to run ssh: \(error.localizedDescription)", retry: false)
            return
        }

        ChildProcessRegistry.shared.register(process)
        connection.process = process
        connections[name] = connection
        Log.control.info("Control connection spawned for \(name, privacy: .private(mask: .hash)), pid=\(process.processIdentifier)")
    }

    private func controlSSHFinished(name: String, token: UUID, process: Process, stderr: Data) {
        guard !isShuttingDown, var connection = connections[name], connection.attemptToken == token else { return }
        connection.clearProcess()

        let message = SSHCommand.errorMessage(stderr: stderr) ?? "SSH exited with code \(process.terminationStatus)"
        Log.control.notice("Control connection ended for \(name, privacy: .private(mask: .hash)), exit=\(process.terminationStatus)")
        fail(connection, message: message, retry: true)
    }

    private func fail(_ connection: ControlConnection, message: String, retry: Bool) {
        var connection = connection
        let name = connection.name
        connection.errorMessage = message
        connection.clearProcess()

        guard retry, !isShuttingDown else {
            connection.status = .error
            connections[name] = connection
            return
        }

        connection.status = .reconnecting
        let delay = ReconnectBackoff.delay(retryCount: connection.retryCount)
        connection.retryCount += 1
        let token = connection.attemptToken
        connection.retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  let current = self.connections[name],
                  current.status == .reconnecting,
                  current.attemptToken == token else { return }
            self.startAttempt(current)
        }
        connections[name] = connection
    }

    private func makeSSHProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executablePath)
        process.arguments = arguments
        process.environment = SSHCommand.environment(authSock: sshAuthSock)
        return process
    }
}

import Foundation
import LarimarShared

/// Manages SSH tunnel processes and their lifecycle.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var tunnelStates: [String: TunnelEntry] = [:]

    private var sshAuthSock: String?

    struct TunnelEntry {
        var config: TunnelConfig
        var status: TunnelStatus
        var process: Process?
        var errorMessage: String?
        var retryCount: Int = 0
        var retryTask: Task<Void, Never>?
        var connectedSince: Date?
    }

    init(config: LarimarConfig) {
        self.sshAuthSock = config.defaults.sshAuthSock
        for tunnel in config.tunnels {
            tunnelStates[tunnel.id] = TunnelEntry(
                config: tunnel,
                status: .stopped
            )
        }
    }

    /// Reload configuration, preserving state for existing tunnels.
    /// Reconnects active tunnels whose SSH parameters changed.
    func reloadConfig(_ config: LarimarConfig) {
        let newIds = Set(config.tunnels.map(\.id))
        let oldIds = Set(tunnelStates.keys)

        // Check if global sshAuthSock changed
        let authSockChanged = sshAuthSock != config.defaults.sshAuthSock
        if authSockChanged {
            sshAuthSock = config.defaults.sshAuthSock
        }

        // Remove tunnels that no longer exist in config
        for id in oldIds.subtracting(newIds) {
            disconnect(tunnelId: id)
            tunnelStates.removeValue(forKey: id)
        }

        // Add new tunnels, update config for existing ones
        for tunnel in config.tunnels {
            if var existing = tunnelStates[tunnel.id] {
                let previousConfig = existing.config
                existing.config = tunnel
                tunnelStates[tunnel.id] = existing

                // Reconnect if SSH parameters changed and tunnel is active
                let isActive = existing.status == .connected
                    || existing.status == .connecting
                    || existing.status == .reconnecting
                if isActive && (tunnel.sshParametersDiffer(from: previousConfig) || authSockChanged) {
                    disconnect(tunnelId: tunnel.id)
                    connect(tunnelId: tunnel.id)
                }
            } else {
                tunnelStates[tunnel.id] = TunnelEntry(config: tunnel, status: .stopped)
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect(tunnelId: String) {
        guard var entry = tunnelStates[tunnelId] else { return }
        guard entry.status == .stopped || entry.status == .error else { return }

        entry.retryTask?.cancel()
        entry.retryTask = nil
        entry.retryCount = 0
        entry.status = .connecting
        entry.errorMessage = nil
        tunnelStates[tunnelId] = entry

        spawnSSH(tunnelId: tunnelId)
    }

    func disconnect(tunnelId: String) {
        guard var entry = tunnelStates[tunnelId] else { return }

        entry.retryTask?.cancel()
        entry.retryTask = nil
        entry.retryCount = 0

        if let process = entry.process, process.isRunning {
            process.terminate()
        }

        entry.process = nil
        entry.status = .stopped
        entry.errorMessage = nil
        entry.connectedSince = nil
        tunnelStates[tunnelId] = entry
    }

    func connectAll() {
        for id in tunnelStates.keys {
            if tunnelStates[id]?.status == .stopped || tunnelStates[id]?.status == .error {
                connect(tunnelId: id)
            }
        }
    }

    func disconnectAll() {
        for id in tunnelStates.keys {
            disconnect(tunnelId: id)
        }
    }

    /// Auto-connect tunnels that have autoConnect enabled.
    func autoConnectIfNeeded() {
        for (id, entry) in tunnelStates where entry.config.autoConnect && entry.status == .stopped {
            connect(tunnelId: id)
        }
    }

    // MARK: - Status

    func tunnelInfos() -> [TunnelInfo] {
        tunnelStates.values
            .map { entry in
                TunnelInfo(
                    id: entry.config.id,
                    status: entry.status,
                    localPort: entry.config.localPort,
                    remotePort: entry.config.remotePort,
                    sshHost: entry.config.sshHost,
                    errorMessage: entry.errorMessage
                )
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: - SSH Process

    private func spawnSSH(tunnelId: String) {
        guard let entry = tunnelStates[tunnelId] else { return }
        let config = entry.config

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = ["-N"]

        // Port forwarding
        let forward = "\(config.bindAddress):\(config.localPort):\(config.remoteHost):\(config.remotePort)"
        args += ["-L", forward]

        // SSH options
        args += ["-o", "ServerAliveInterval=15"]
        args += ["-o", "ServerAliveCountMax=3"]
        args += ["-o", "ExitOnForwardFailure=yes"]
        args += ["-o", "BatchMode=yes"]

        // Optional user/port from tunnel config (otherwise delegated to ~/.ssh/config)
        if let user = config.sshUser {
            args += ["-l", user]
        }
        if let port = config.sshPort {
            args += ["-p", String(port)]
        }

        args.append(config.sshHost)
        process.arguments = args

        // Environment: inherit parent, optionally override SSH_AUTH_SOCK
        var env = ProcessInfo.processInfo.environment
        if let sock = sshAuthSock {
            env["SSH_AUTH_SOCK"] = NSString(string: sock).expandingTildeInPath
        }
        process.environment = env

        // Silence stdout/stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()

        // Monitor process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(tunnelId: tunnelId, process: proc)
            }
        }

        do {
            try process.run()
            tunnelStates[tunnelId]?.process = process
            // Mark connected after a short delay to confirm the process stays alive
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                if tunnelStates[tunnelId]?.process?.isRunning == true {
                    tunnelStates[tunnelId]?.status = .connected
                    tunnelStates[tunnelId]?.connectedSince = Date()
                }
            }
        } catch {
            tunnelStates[tunnelId]?.status = .error
            tunnelStates[tunnelId]?.errorMessage = error.localizedDescription
            tunnelStates[tunnelId]?.process = nil
        }
    }

    private func handleTermination(tunnelId: String, process: Process) {
        guard var entry = tunnelStates[tunnelId],
              entry.process === process else { return }

        entry.process = nil
        entry.connectedSince = nil

        // If status is .stopped, user explicitly disconnected — do nothing
        guard entry.status != .stopped else { return }

        let exitCode = process.terminationStatus

        if entry.config.autoReconnect {
            // Read stderr for error context
            let errorMessage: String?
            if let pipe = process.standardError as? Pipe {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = stderr?.isEmpty == false ? stderr : "SSH exited with code \(exitCode)"
            } else {
                errorMessage = "SSH exited with code \(exitCode)"
            }

            entry.status = .reconnecting
            entry.errorMessage = errorMessage
            tunnelStates[tunnelId] = entry
            scheduleReconnect(tunnelId: tunnelId)
        } else {
            entry.status = .error
            entry.errorMessage = "SSH exited with code \(exitCode)"
            tunnelStates[tunnelId] = entry
        }
    }

    // MARK: - Reconnect

    /// Schedule a reconnection attempt with exponential backoff and jitter.
    func scheduleReconnect(tunnelId: String) {
        guard var entry = tunnelStates[tunnelId],
              entry.status == .reconnecting else { return }

        let retryCount = entry.retryCount
        let baseDelay = min(pow(2.0, Double(retryCount)), 300.0) // max 300s
        let jitter = baseDelay * Double.random(in: -0.25...0.25)
        let delay = max(1.0, baseDelay + jitter)

        entry.retryCount += 1
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard tunnelStates[tunnelId]?.status == .reconnecting else { return }
            tunnelStates[tunnelId]?.status = .connecting
            spawnSSH(tunnelId: tunnelId)
        }
        entry.retryTask = task
        tunnelStates[tunnelId] = entry
    }

    /// Reset retry counters for tunnels that have been connected long enough (60s).
    func resetStableRetryCounters() {
        let now = Date()
        for (id, entry) in tunnelStates {
            if entry.status == .connected,
               let since = entry.connectedSince,
               now.timeIntervalSince(since) > 60 {
                tunnelStates[id]?.retryCount = 0
            }
        }
    }

    /// Immediately retry all reconnecting tunnels (e.g., on network change).
    func retryAllReconnecting() {
        for (id, entry) in tunnelStates where entry.status == .reconnecting {
            tunnelStates[id]?.retryTask?.cancel()
            tunnelStates[id]?.retryTask = nil
            tunnelStates[id]?.retryCount = 0
            tunnelStates[id]?.status = .connecting
            spawnSSH(tunnelId: id)
        }
    }
}

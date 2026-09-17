import Foundation
import LarimarShared
import OSLog

/// Manages SSH tunnel processes and their lifecycle.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var tunnelStates: [String: TunnelEntry] = [:]

    private var sshAuthSock: String?
    private var isShuttingDown = false

    struct TunnelEntry {
        var config: TunnelConfig
        var status: TunnelStatus
        var process: Process?
        var errorMessage: String?
        var retryCount: Int = 0
        var retryTask: Task<Void, Never>?
        var connectedSince: Date?
        var source: TunnelSource = .config
        /// Control host that created a dynamic tunnel.
        var owner: ControlOwner?
        var hint: String?

        var isActive: Bool { status.isActive }
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
    /// Only config-sourced entries are touched; dynamic tunnels are managed
    /// through the control socket.
    func reloadConfig(_ config: LarimarConfig) {
        let newIds = Set(config.tunnels.map(\.id))
        let oldIds = Set(tunnelStates.filter { $0.value.source == .config }.keys)

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
                // Config ids cannot contain ':' so they never collide with dynamic ids
                guard existing.source == .config else { continue }
                let previousConfig = existing.config
                existing.config = tunnel
                tunnelStates[tunnel.id] = existing

                // Reconnect if SSH parameters changed and tunnel is active
                if existing.isActive && (tunnel.sshParametersDiffer(from: previousConfig) || authSockChanged) {
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
        guard !isShuttingDown else { return }
        guard var entry = tunnelStates[tunnelId] else { return }
        guard entry.status == .stopped || entry.status == .error else { return }

        entry.retryTask?.cancel()
        entry.retryTask = nil
        entry.retryCount = 0
        entry.status = .connecting
        entry.errorMessage = nil
        tunnelStates[tunnelId] = entry
        Log.ssh.info("Connecting tunnel \(tunnelId, privacy: .private(mask: .hash))")

        spawnSSH(tunnelId: tunnelId)
    }

    func disconnect(tunnelId: String) {
        guard var entry = tunnelStates[tunnelId] else { return }

        entry.retryTask?.cancel()
        entry.retryTask = nil
        entry.retryCount = 0

        // The process stays tracked by ChildProcessRegistry until it exits
        if let process = entry.process, process.isRunning {
            Log.ssh.info("Disconnecting tunnel \(tunnelId, privacy: .private(mask: .hash))")
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

    /// Stop all tunnels and refuse new connections. Children are reaped by ChildProcessRegistry.
    func shutdown() {
        isShuttingDown = true
        disconnectAll()
    }

    /// Auto-connect tunnels that have autoConnect enabled.
    func autoConnectIfNeeded() {
        for (id, entry) in tunnelStates where entry.config.autoConnect && entry.status == .stopped {
            connect(tunnelId: id)
        }
    }

    // MARK: - Dynamic Tunnels

    /// Add and connect a dynamic tunnel. Returns the generated id.
    func addDynamic(owner: ControlOwner, identity: ControlHostIdentity, request: ForwardRequest, localPort: UInt16) -> String? {
        guard !isShuttingDown else { return nil }

        var id: String
        repeat {
            id = "dyn:" + String(format: "%08x", UInt32.random(in: .min ... .max))
        } while tunnelStates[id] != nil

        let config = TunnelConfig(
            id: id,
            mode: .local,
            localPort: localPort,
            remotePort: request.remotePort,
            forwardHost: request.forwardHost,
            sshHost: identity.sshHost,
            sshUser: identity.sshUser,
            sshPort: identity.sshPort,
            bindAddress: "127.0.0.1",
            autoConnect: false,
            autoReconnect: true,
            app: request.app
        )
        tunnelStates[id] = TunnelEntry(
            config: config,
            status: .stopped,
            source: .dynamic,
            owner: owner,
            hint: request.hint
        )
        Log.control.info("Dynamic tunnel created: \(id, privacy: .private(mask: .hash)) owner=\(owner.name, privacy: .private(mask: .hash))")
        connect(tunnelId: id)
        return id
    }

    func removeDynamic(tunnelId: String) {
        guard tunnelStates[tunnelId]?.source == .dynamic else { return }
        disconnect(tunnelId: tunnelId)
        tunnelStates.removeValue(forKey: tunnelId)
        Log.control.info("Dynamic tunnel removed: \(tunnelId, privacy: .private(mask: .hash))")
    }

    /// Remove every dynamic tunnel whose owner matches the predicate.
    func removeDynamics(where predicate: (ControlOwner) -> Bool) {
        let ids = tunnelStates.compactMap { id, entry -> String? in
            guard entry.source == .dynamic, let owner = entry.owner, predicate(owner) else { return nil }
            return id
        }
        for id in ids {
            removeDynamic(tunnelId: id)
        }
    }

    func setHint(tunnelId: String, hint: String?) {
        guard let entry = tunnelStates[tunnelId], entry.hint != hint else { return }
        tunnelStates[tunnelId]?.hint = hint
    }

    /// Local ports already assigned to any tunnel.
    func allocatedLocalPorts() -> Set<UInt16> {
        Set(tunnelStates.values.filter { $0.config.mode != .remote }.map(\.config.localPort))
    }

    func forwardCandidates() -> [ForwardCandidate] {
        tunnelStates.values.map(Self.candidate(for:))
    }

    func forwardCandidate(id: String) -> ForwardCandidate? {
        tunnelStates[id].map(Self.candidate(for:))
    }

    private static func candidate(for entry: TunnelEntry) -> ForwardCandidate {
        ForwardCandidate(
            id: entry.config.id,
            source: entry.source,
            mode: entry.config.mode,
            sshHost: entry.config.sshHost,
            sshUser: entry.config.sshUser,
            sshPort: entry.config.sshPort,
            forwardHost: entry.config.forwardHost,
            remotePort: entry.config.remotePort,
            localPort: entry.config.localPort,
            owner: entry.owner,
            isActive: entry.isActive
        )
    }

    // MARK: - Status

    func tunnelInfos() -> [TunnelInfo] {
        tunnelStates.values
            .map(Self.info(for:))
            .sorted { $0.id < $1.id }
    }

    func tunnelInfo(id: String) -> TunnelInfo? {
        tunnelStates[id].map(Self.info(for:))
    }

    private static func info(for entry: TunnelEntry) -> TunnelInfo {
        TunnelInfo(
            id: entry.config.id,
            status: entry.status,
            mode: entry.config.mode,
            localPort: entry.config.localPort,
            remotePort: entry.config.remotePort,
            sshHost: entry.config.sshHost,
            errorMessage: entry.errorMessage,
            source: entry.source,
            app: entry.config.app,
            hint: entry.hint,
            owner: entry.owner?.name,
            forwardHost: entry.config.forwardHost
        )
    }

    // MARK: - SSH Process

    private func spawnSSH(tunnelId: String) {
        guard let entry = tunnelStates[tunnelId] else { return }
        let config = entry.config

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executablePath)
        process.arguments = SSHCommand.forwardingArguments(
            forward: config.sshForwardArguments(),
            sshHost: config.sshHost,
            sshUser: config.sshUser,
            sshPort: config.sshPort
        )

        process.environment = SSHCommand.environment(authSock: sshAuthSock)

        // stdout carries only the ready marker from LocalCommand
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        SSHCommand.watchReady(stdout: stdout) { [weak self] in
            Task { @MainActor [weak self] in
                self?.markConnected(tunnelId: tunnelId, process: process)
            }
        }

        // Monitor process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(tunnelId: tunnelId, process: proc)
            }
        }

        do {
            try process.run()
            ChildProcessRegistry.shared.register(process)
            Log.ssh.info("SSH spawned for \(tunnelId, privacy: .private(mask: .hash)), pid=\(process.processIdentifier)")
            tunnelStates[tunnelId]?.process = process
        } catch {
            Log.ssh.error("Failed to spawn SSH for \(tunnelId, privacy: .private(mask: .hash)): \(error, privacy: .private)")
            tunnelStates[tunnelId]?.status = .error
            tunnelStates[tunnelId]?.errorMessage = error.localizedDescription
            tunnelStates[tunnelId]?.process = nil
        }
    }

    private func markConnected(tunnelId: String, process: Process) {
        guard let entry = tunnelStates[tunnelId], entry.process === process,
              entry.status == .connecting, process.isRunning else { return }
        Log.ssh.info("SSH authenticated for \(tunnelId, privacy: .private(mask: .hash))")
        tunnelStates[tunnelId]?.status = .connected
        tunnelStates[tunnelId]?.errorMessage = nil
        tunnelStates[tunnelId]?.connectedSince = Date()
    }

    private func handleTermination(tunnelId: String, process: Process) {
        guard var entry = tunnelStates[tunnelId],
              entry.process === process else { return }

        entry.process = nil
        entry.connectedSince = nil

        // If status is .stopped, user explicitly disconnected — do nothing
        guard entry.status != .stopped else { return }

        let exitCode = process.terminationStatus

        // Read stderr for error context
        let stderr = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errorMessage = SSHCommand.errorMessage(stderr: stderr) ?? "SSH exited with code \(exitCode)"

        if entry.config.autoReconnect && !isShuttingDown {
            Log.ssh.notice("SSH terminated for \(tunnelId, privacy: .private(mask: .hash)), exit=\(exitCode), stderr: \(errorMessage, privacy: .private(mask: .hash)), scheduling reconnect")
            entry.status = .reconnecting
            entry.errorMessage = errorMessage
            tunnelStates[tunnelId] = entry
            scheduleReconnect(tunnelId: tunnelId)
        } else {
            Log.ssh.error("SSH terminated for \(tunnelId, privacy: .private(mask: .hash)), exit=\(exitCode), autoReconnect disabled")
            entry.status = .error
            entry.errorMessage = errorMessage
            tunnelStates[tunnelId] = entry
        }
    }

    // MARK: - Reconnect

    /// Schedule a reconnection attempt with exponential backoff and jitter.
    func scheduleReconnect(tunnelId: String) {
        guard var entry = tunnelStates[tunnelId],
              entry.status == .reconnecting else { return }

        let delay = ReconnectBackoff.delay(retryCount: entry.retryCount)

        entry.retryCount += 1
        Log.ssh.info("Scheduling reconnect for \(tunnelId, privacy: .private(mask: .hash)) in \(String(format: "%.1f", delay))s (attempt \(entry.retryCount))")
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isShuttingDown else { return }
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
        // Skip no-op writes: every assignment publishes and re-renders the menu
        for (id, entry) in tunnelStates where entry.retryCount != 0 {
            if entry.status == .connected,
               let since = entry.connectedSince,
               now.timeIntervalSince(since) > ReconnectBackoff.stableAfter {
                tunnelStates[id]?.retryCount = 0
            }
        }
    }

    /// Immediately retry all reconnecting tunnels (e.g., on network change).
    func retryAllReconnecting() {
        guard !isShuttingDown else { return }
        for (id, entry) in tunnelStates where entry.status == .reconnecting {
            tunnelStates[id]?.retryTask?.cancel()
            tunnelStates[id]?.retryTask = nil
            tunnelStates[id]?.retryCount = 0
            tunnelStates[id]?.status = .connecting
            spawnSSH(tunnelId: id)
        }
    }
}

import SwiftUI
import LarimarShared
import OSLog

@main
struct LarimarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.hasActiveConnection ? "network" : "network.slash")
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let tunnelManager: TunnelManager
    private var ipcServer: IPCServer?
    private var configWatcher: ConfigWatcher?
    private var networkMonitor: NetworkMonitor?
    private var stabilityTimer: Timer?

    @Published var hasActiveConnection = false
    @Published var configError: String?
    @Published var configWarnings: [String] = []

    /// True when managed by home-manager (detected via config `managed = true`).
    /// Hides the "Launch at Login" toggle to avoid conflict with launchd.
    let isManagedLaunch: Bool

    init() {
        // Prevent duplicate instances: if another daemon is already listening
        // on the IPC socket, exit immediately.
        if Self.isAnotherInstanceRunning() {
            Log.daemon.notice("Another instance is already running. Exiting.")
            exit(0)
        }

        let config: LarimarConfig
        do {
            let result = try ConfigLoader.load()
            config = result.config
            configWarnings = result.warnings
            Log.config.info("Configuration loaded: \(config.tunnels.count) tunnel(s)")
        } catch {
            Log.config.error("Failed to load configuration: \(error, privacy: .private)")
            configError = error.localizedDescription
            config = LarimarConfig(defaults: DefaultsConfig(), tunnels: [])
        }

        self.isManagedLaunch = config.managed

        self.tunnelManager = TunnelManager(config: config)

        // Observe tunnel state changes
        tunnelManager.$tunnelStates
            .map { states in states.values.contains { $0.status == .connected || $0.status == .connecting } }
            .assign(to: &$hasActiveConnection)

        // Start IPC server
        do {
            let server = IPCServer(tunnelManager: tunnelManager)
            try server.start()
            self.ipcServer = server
        } catch {
            Log.ipc.error("Failed to start IPC server: \(error, privacy: .private)")
        }

        // Config file watcher
        configWatcher = ConfigWatcher { [weak self] in
            self?.reloadConfig()
        }

        // Network monitor for reconnection on network change
        networkMonitor = NetworkMonitor { [weak self] in
            self?.tunnelManager.retryAllReconnecting()
        }

        // Periodically reset retry counters for stable connections
        stabilityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tunnelManager.resetStableRetryCounters()
            }
        }

        // Auto-connect configured tunnels
        tunnelManager.autoConnectIfNeeded()
    }

    /// Check if another daemon instance is already running by attempting
    /// to connect to the IPC socket. A successful connect means the socket
    /// is actively listened on by another process.
    private static func isAnotherInstanceRunning() -> Bool {
        let path = LarimarConstants.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bytes = path.utf8CString
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                bytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func reloadConfig() {
        do {
            let result = try ConfigLoader.load()
            configError = nil
            configWarnings = result.warnings
            tunnelManager.reloadConfig(result.config)
            Log.config.info("Configuration reloaded: \(result.config.tunnels.count) tunnel(s)")
        } catch {
            Log.config.error("Failed to reload configuration: \(error, privacy: .private)")
            configError = error.localizedDescription
            configWarnings = []
        }
    }
}

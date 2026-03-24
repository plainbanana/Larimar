import SwiftUI
import LarimarShared

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

    init() {
        let config: LarimarConfig
        do {
            let result = try ConfigLoader.load()
            config = result.config
            configWarnings = result.warnings
        } catch {
            configError = error.localizedDescription
            config = LarimarConfig(defaults: DefaultsConfig(), tunnels: [])
        }

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
            print("[Larimar] Failed to start IPC server: \(error)")
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

    private func reloadConfig() {
        do {
            let result = try ConfigLoader.load()
            configError = nil
            configWarnings = result.warnings
            tunnelManager.reloadConfig(result.config)
        } catch {
            configError = error.localizedDescription
            configWarnings = []
        }
    }
}

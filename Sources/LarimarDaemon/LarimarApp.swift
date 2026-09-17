import AppKit
import Combine
import SwiftUI
import LarimarShared
import OSLog

@main
struct LarimarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.menuBarSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Defer termination until tunnels, control connections and sockets are cleaned up.
    /// Larimar's own quit paths shut down first and then call terminate, so this
    /// only defers for external requests (e.g. logout).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ AppState.shared.isShutdownComplete }) {
            return .terminateNow
        }
        Task { @MainActor in
            await AppState.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let tunnelManager: TunnelManager
    let controlConnections: ControlConnectionManager
    let approvals: ApprovalCoordinator
    private var controlServer: ControlServer?
    private var ipcServer: IPCServer?
    private var configWatcher: ConfigWatcher?
    private var networkMonitor: NetworkMonitor?
    private var stabilityTimer: Timer?
    private var signalSource: DispatchSourceSignal?
    private var cancellables: Set<AnyCancellable> = []
    private var shutdownTask: Task<Void, Never>?
    private(set) var isShutdownComplete = false

    @Published var hasActiveConnection = false
    @Published var hasPendingConnection = false
    @Published var configError: String?
    @Published var configWarnings: [String] = []
    @Published private(set) var controlEnabled = false

    var menuBarSymbol: String {
        if hasPendingConnection { return "hourglass" }
        return hasActiveConnection ? "network" : "network.slash"
    }

    /// True when managed by home-manager (detected via config `managed = true`).
    /// Hides the "Launch at Login" toggle to avoid conflict with launchd.
    let isManagedLaunch: Bool

    private init() {
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
        self.controlConnections = ControlConnectionManager()
        self.approvals = ApprovalCoordinator()

        // Observe tunnel state changes
        tunnelManager.$tunnelStates
            .map { states in states.values.contains { $0.status == .connected || $0.status == .connecting } }
            .assign(to: &$hasActiveConnection)
        tunnelManager.$tunnelStates
            .combineLatest(controlConnections.$connections)
            .map { tunnels, controls in
                tunnels.values.contains { $0.status == .connecting }
                    || controls.values.contains { $0.status == .preparing || $0.status == .connecting }
            }
            .removeDuplicates()
            .assign(to: &$hasPendingConnection)

        // Re-render the menu when nested managers change
        for publisher in [tunnelManager.objectWillChange, controlConnections.objectWillChange, approvals.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        installTerminationSignalHandler()

        // Start IPC server
        do {
            let server = IPCServer(tunnelManager: tunnelManager, controlConnections: controlConnections)
            try server.start()
            self.ipcServer = server
        } catch {
            Log.ipc.error("Failed to start IPC server: \(error, privacy: .private)")
        }

        // Control sockets for allowed remote hosts
        controlServer = ControlServer(tunnelManager: tunnelManager, controlConnections: controlConnections, approvals: approvals)
        applyControl(config)

        // Config file watcher
        configWatcher = ConfigWatcher { [weak self] in
            self?.reloadConfig()
        }

        // Network monitor for reconnection on network change
        networkMonitor = NetworkMonitor { [weak self] in
            self?.tunnelManager.retryAllReconnecting()
            self?.controlConnections.retryAllReconnecting()
        }

        // Periodically reset retry counters for stable connections
        stabilityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tunnelManager.resetStableRetryCounters()
                self?.controlConnections.resetStableRetryCounters()
            }
        }

        // Auto-connect configured tunnels
        tunnelManager.autoConnectIfNeeded()
    }

    /// Stop everything and wait (bounded) for child processes to exit. Idempotent.
    func shutdown() async {
        if let task = shutdownTask {
            await task.value
            return
        }
        let task = Task { @MainActor in
            Log.daemon.info("Shutting down")
            stabilityTimer?.invalidate()
            controlServer?.stop()
            approvals.shutdown()
            controlConnections.shutdown()
            tunnelManager.shutdown()
            await ChildProcessRegistry.shared.terminateAll(grace: 3)
            ipcServer?.stop()
            isShutdownComplete = true
        }
        shutdownTask = task
        await task.value
    }

    /// Shut down, then terminate the app.
    /// Shutdown must finish before calling terminate: when terminate is invoked
    /// from a main-queue callback, `.terminateLater` spins a nested run loop that
    /// cannot drain the main queue, so the cleanup task would never run.
    func quit() {
        Task { @MainActor in
            await shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Handle SIGTERM (e.g. from launchd) through the normal quit path.
    /// A no-op handler is installed instead of SIG_IGN so that child processes
    /// do not inherit an ignored SIGTERM (handlers reset to default on exec).
    private func installTerminationSignalHandler() {
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Log.daemon.notice("Received SIGTERM")
            self?.quit()
        }
        source.resume()
        signalSource = source
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

    private func applyControl(_ config: LarimarConfig) {
        controlServer?.apply(config.control, sshAuthSock: config.defaults.sshAuthSock)
        controlEnabled = config.control.enabled
    }

    private func reloadConfig() {
        guard shutdownTask == nil else { return }
        do {
            let result = try ConfigLoader.load()
            configError = nil
            configWarnings = result.warnings
            tunnelManager.reloadConfig(result.config)
            applyControl(result.config)
            Log.config.info("Configuration reloaded: \(result.config.tunnels.count) tunnel(s)")
        } catch {
            Log.config.error("Failed to reload configuration: \(error, privacy: .private)")
            configError = error.localizedDescription
            configWarnings = []
        }
    }
}

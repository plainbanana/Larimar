import Foundation
import Network
import LarimarShared

/// Monitors network path changes and notifies when connectivity is restored.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.larimar.network-monitor")
    private let onNetworkRestored: @Sendable () -> Void
    private var wasUnsatisfied = false

    init(onNetworkRestored: @MainActor @escaping () -> Void) {
        self.onNetworkRestored = { @Sendable in
            Task { @MainActor in onNetworkRestored() }
        }
        self.monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied && self.wasUnsatisfied {
                self.wasUnsatisfied = false
                self.onNetworkRestored()
            } else if path.status != .satisfied {
                self.wasUnsatisfied = true
            }
        }

        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// Watches the configuration file for changes and triggers reload.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let onChange: () -> Void

    init(onChange: @MainActor @escaping () -> Void) {
        self.onChange = {
            Task { @MainActor in onChange() }
        }
        startWatching()
    }

    deinit {
        source?.cancel()
    }

    private func startWatching() {
        let path = LarimarConstants.defaultConfigPath

        // Ensure the config file exists before watching
        guard FileManager.default.fileExists(atPath: path) else {
            // Retry after a delay if config doesn't exist yet
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startWatching()
            }
            return
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced — restart watcher (cancel handler closes fd)
                source.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startWatching()
                }
            }
            self.onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }
}

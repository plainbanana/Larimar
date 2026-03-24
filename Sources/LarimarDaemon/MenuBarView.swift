import SwiftUI
import LarimarShared
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let infos = appState.tunnelManager.tunnelInfos()

        // Config error / warnings
        if let error = appState.configError {
            Text("Config error: \(error)")
                .foregroundStyle(.red)
            Divider()
        }
        if !appState.configWarnings.isEmpty {
            Text("\(appState.configWarnings.count) tunnel(s) skipped (invalid config)")
                .foregroundStyle(.secondary)
            ForEach(appState.configWarnings, id: \.self) { warning in
                Text("  \(warning)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Divider()
        }

        if infos.isEmpty && appState.configError == nil {
            Text("No tunnels configured")
                .foregroundStyle(.secondary)
        } else {
            ForEach(infos, id: \.id) { tunnel in
                tunnelRow(tunnel)
            }
        }

        Divider()

        Button("Connect All") {
            appState.tunnelManager.connectAll()
        }
        .disabled(infos.allSatisfy { $0.status == .connected || $0.status == .connecting })

        Button("Disconnect All") {
            appState.tunnelManager.disconnectAll()
        }
        .disabled(infos.allSatisfy { $0.status == .stopped })

        Divider()

        Button("Edit Configuration...") {
            openConfig()
        }

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                setLaunchAtLogin(newValue)
            }

        Divider()

        Button("Quit") {
            appState.tunnelManager.disconnectAll()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func tunnelRow(_ tunnel: TunnelInfo) -> some View {
        let isActive = tunnel.status == .connected || tunnel.status == .connecting || tunnel.status == .reconnecting
        let icon = statusIcon(tunnel.status)
        let label = "\(icon) \(tunnel.id)  [\(tunnel.status.rawValue)]  :\(tunnel.localPort)"

        Button(label) {
            if isActive {
                appState.tunnelManager.disconnect(tunnelId: tunnel.id)
            } else {
                appState.tunnelManager.connect(tunnelId: tunnel.id)
            }
        }
    }

    private func statusIcon(_ status: TunnelStatus) -> String {
        switch status {
        case .connected: return "●"
        case .connecting: return "◐"
        case .reconnecting: return "◐"
        case .stopped: return "○"
        case .error: return "✗"
        }
    }

    private func openConfig() {
        let path = LarimarConstants.defaultConfigPath
        let dir = (path as NSString).deletingLastPathComponent

        // Ensure config directory exists
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        // Create default config if it doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            let defaultConfig = """
            [defaults]
            bind_address = "127.0.0.1"
            auto_connect = false
            auto_reconnect = true

            # [tunnels.example]
            # local_port = 8080
            # remote_port = 8080
            # remote_host = "localhost"
            # ssh_host = "myserver"
            """
            FileManager.default.createFile(atPath: path, contents: Data(defaultConfig.utf8))
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Larimar] Failed to set launch at login: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

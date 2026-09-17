import SwiftUI
import LarimarShared
import ServiceManagement
import OSLog

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
            Text("\(appState.configWarnings.count) config warning(s)")
                .foregroundStyle(.secondary)
            ForEach(appState.configWarnings, id: \.self) { warning in
                Text("  \(warning)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Divider()
        }

        // Pending approvals
        if !appState.approvals.pendingItems.isEmpty {
            Section("Pending Approvals") {
                ForEach(appState.approvals.pendingItems) { item in
                    approvalMenu(item)
                }
            }
            Divider()
        }

        // Recently denied requests; clearing one lets the same request prompt again
        if !appState.approvals.deniedItems.isEmpty {
            Section("Recently Denied") {
                ForEach(appState.approvals.deniedItems) { item in
                    deniedMenu(item)
                }
            }
            Divider()
        }

        let configured = MenuGrouping.groups(infos, source: .config)
        let dynamic = MenuGrouping.groups(infos, source: .dynamic)

        if infos.isEmpty && appState.configError == nil {
            Text("No tunnels configured")
                .foregroundStyle(.secondary)
        } else {
            groupedSection("Configured", configured, row: tunnelMenu)
            groupedSection("Dynamic", dynamic, row: tunnelMenu)
        }

        // Control connections
        if appState.controlEnabled {
            Divider()
            Section("Control") {
                let controls = appState.controlConnections.controlInfos()
                if controls.isEmpty {
                    Text("No control hosts configured")
                        .foregroundStyle(.secondary)
                }
                ForEach(controls, id: \.name) { control in
                    controlRow(control)
                }
                Button("Remove All Dynamic") {
                    appState.tunnelManager.removeDynamics { _ in true }
                }
                .disabled(dynamic.isEmpty)
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

        if !appState.isManagedLaunch {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }
        } else {
            Toggle("Launch at Login", isOn: .constant(true))
                .disabled(true)
            Text("  Managed by launchd (home-manager)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }

        Divider()

        Text("Larimar \(LarimarVersion.current)")
            .foregroundStyle(.secondary)
            .font(.caption)

        Button("Quit") {
            appState.quit()
        }
        .keyboardShortcut("q")
    }

    /// A titled section of tunnels; tunnels sharing an app are nested in a submenu.
    @ViewBuilder
    private func groupedSection<Row: View>(
        _ title: String,
        _ groups: [MenuItemGroup],
        @ViewBuilder row: @escaping (TunnelInfo) -> Row
    ) -> some View {
        if !groups.isEmpty {
            Section(title) {
                ForEach(groups) { group in
                    switch group {
                    case .app(let name, let tunnels):
                        Menu(name) {
                            ForEach(tunnels, id: \.id, content: row)
                        }
                    case .single(let tunnel):
                        row(tunnel)
                    }
                }
            }
        }
    }

    /// Submenu for one tunnel. Browser actions are offered for local forwards only;
    /// Remove is offered for dynamic tunnels only.
    @ViewBuilder
    private func tunnelMenu(_ tunnel: TunnelInfo) -> some View {
        let isActive = tunnel.status.isActive
        let hint = tunnel.hint.map { "  — \($0)" } ?? ""
        let title: String = switch tunnel.source {
        case .config:
            "\(tunnel.status.icon) \(tunnel.id)  [\(tunnel.status.rawValue)]  \(portLabel(tunnel))\(hint)"
        case .dynamic:
            "\(tunnel.status.icon) :\(tunnel.localPort) → \(tunnel.owner ?? tunnel.sshHost):\(tunnel.remotePort)\(hint)"
        }

        Menu(title) {
            Text("\(tunnel.id)  [\(tunnel.status.rawValue)]")
            if tunnel.status == .connecting {
                Text(Self.awaitingAuthNote)
            }
            if let error = tunnel.errorMessage {
                Text(error)
            }
            Divider()
            if tunnel.mode == .local {
                Button("Open in Browser") {
                    if let target = URL(string: tunnel.localURL) {
                        NSWorkspace.shared.open(target)
                    }
                }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tunnel.localURL, forType: .string)
                }
            }
            Button(isActive ? "Disconnect" : "Connect") {
                if isActive {
                    appState.tunnelManager.disconnect(tunnelId: tunnel.id)
                } else {
                    appState.tunnelManager.connect(tunnelId: tunnel.id)
                }
            }
            if tunnel.hint != nil {
                Button("Clear Hint") {
                    appState.tunnelManager.setHint(tunnelId: tunnel.id, hint: nil)
                }
            }
            if tunnel.source == .dynamic {
                Button("Remove") {
                    appState.tunnelManager.removeDynamic(tunnelId: tunnel.id)
                }
            }
        }
    }

    @ViewBuilder
    private func deniedMenu(_ item: ApprovalCoordinator.DeniedItem) -> some View {
        let request = item.details.request
        Menu("🚫 \(item.details.summary)") {
            Text("Host: \(item.details.hostName) (\(item.details.sshHost))")
            Text("Remote: \(request.forwardHost):\(request.remotePort)")
            Text("Local port: \(item.details.localPortDescription)")
            if let hint = item.hint {
                Text("Hint: \(hint)")
            }
            Text("Blocked until \(item.until.formatted(date: .omitted, time: .standard))")
            Divider()
            Button("Clear Denial (ask again on next request)") {
                appState.approvals.clearDenial(item.key)
            }
        }
    }

    @ViewBuilder
    private func approvalMenu(_ item: ApprovalCoordinator.PendingItem) -> some View {
        let request = item.details.request
        Menu("⏳ \(item.details.summary)") {
            Text("Host: \(item.details.hostName) (\(item.details.sshHost))")
            Text("Remote: \(request.forwardHost):\(request.remotePort)")
            Text("Local port: \(item.details.localPortDescription)")
            if let hint = item.hint {
                Text("Hint: \(hint)")
            }
            Divider()
            Button("Allow") {
                appState.approvals.allow(item.id)
            }
            Button("Deny") {
                appState.approvals.deny(item.id)
            }
        }
    }

    @ViewBuilder
    private func controlRow(_ control: ControlInfo) -> some View {
        let isActive = control.status.isActive
        Button("\(control.status.icon) \(control.name)  [\(control.status.rawValue)]") {
            if isActive {
                appState.controlConnections.disconnect(name: control.name)
            } else {
                appState.controlConnections.connect(name: control.name)
            }
        }
        if control.status == .preparing || control.status == .connecting {
            Text("  \(Self.awaitingAuthNote)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        if let error = control.errorMessage, control.status == .error || control.status == .reconnecting {
            Text("  \(error)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    static let awaitingAuthNote = "Waiting for SSH authentication — check 1Password / your SSH agent"

    private func portLabel(_ tunnel: TunnelInfo) -> String {
        switch tunnel.mode {
        case .local:
            return "-L :\(tunnel.localPort)"
        case .remote:
            return "-R :\(tunnel.remotePort)"
        case .dynamic:
            return "-D :\(tunnel.localPort)"
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
            # mode = "local"            # "local" (-L), "remote" (-R), or "dynamic" (-D)
            # local_port = 8080
            # remote_port = 8080
            # forward_host = "localhost"
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
            Log.daemon.error("Failed to set launch at login: \(error, privacy: .private)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

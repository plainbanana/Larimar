import Foundation

public enum MenuItemGroup: Sendable, Identifiable {
    /// Tunnels sharing an app name.
    case app(name: String, tunnels: [TunnelInfo])
    /// A tunnel without an app name.
    case single(TunnelInfo)

    public var id: String {
        switch self {
        case .app(let name, _): return "app:\(name)"
        case .single(let tunnel): return "tunnel:\(tunnel.id)"
        }
    }

    fileprivate var sortKey: String {
        switch self {
        case .app(let name, _): return name
        case .single(let tunnel): return tunnel.id
        }
    }
}

public enum MenuGrouping {
    /// Group tunnels of one source by app; tunnels without an app stay flat.
    public static func groups(_ tunnels: [TunnelInfo], source: TunnelSource) -> [MenuItemGroup] {
        let filtered = tunnels.filter { $0.source == source }
        var byApp: [String: [TunnelInfo]] = [:]
        var items: [MenuItemGroup] = []

        for tunnel in filtered {
            if let app = tunnel.app {
                byApp[app, default: []].append(tunnel)
            } else {
                items.append(.single(tunnel))
            }
        }
        for (app, members) in byApp {
            let sorted = members.sorted { ($0.localPort, $0.id) < ($1.localPort, $1.id) }
            items.append(.app(name: app, tunnels: sorted))
        }
        return items.sorted { $0.sortKey < $1.sortKey }
    }
}

import Foundation

public enum TunnelStatus: String, Codable, Sendable {
    case stopped = "stopped"
    case connecting = "connecting"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case error = "error"

    /// Whether a connection exists or is being (re-)established.
    public var isActive: Bool {
        self == .connected || self == .connecting || self == .reconnecting
    }

    /// Single-glyph indicator shared by the menu and the CLI.
    public var icon: String {
        switch self {
        case .connected: return "●"
        case .connecting, .reconnecting: return "◐"
        case .stopped: return "○"
        case .error: return "✗"
        }
    }
}

/// Where a tunnel definition came from.
public enum TunnelSource: String, Codable, Sendable {
    /// Defined in tunnels.toml.
    case config = "config"
    /// Added at runtime through the control socket after user approval.
    case dynamic = "dynamic"
}

public struct TunnelInfo: Codable, Sendable {
    public let id: String
    public let status: TunnelStatus
    public let mode: TunnelMode
    public let localPort: UInt16
    public let remotePort: UInt16
    public let sshHost: String
    public let errorMessage: String?
    public let source: TunnelSource
    public let app: String?
    public let hint: String?
    /// Control host name that owns a dynamic tunnel.
    public let owner: String?
    public let forwardHost: String

    public init(
        id: String,
        status: TunnelStatus,
        mode: TunnelMode = .local,
        localPort: UInt16,
        remotePort: UInt16,
        sshHost: String,
        errorMessage: String? = nil,
        source: TunnelSource = .config,
        app: String? = nil,
        hint: String? = nil,
        owner: String? = nil,
        forwardHost: String = "localhost"
    ) {
        self.id = id
        self.status = status
        self.mode = mode
        self.localPort = localPort
        self.remotePort = remotePort
        self.sshHost = sshHost
        self.errorMessage = errorMessage
        self.source = source
        self.app = app
        self.hint = hint
        self.owner = owner
        self.forwardHost = forwardHost
    }

    /// URL of the local end of the forward.
    public var localURL: String {
        "http://127.0.0.1:\(localPort)"
    }

    // Backward-compatible decoding: fields added later default when absent from JSON
    private enum CodingKeys: String, CodingKey {
        case id, status, mode, localPort, remotePort, sshHost, errorMessage
        case source, app, hint, owner, forwardHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(TunnelStatus.self, forKey: .status)
        mode = try container.decodeIfPresent(TunnelMode.self, forKey: .mode) ?? .local
        localPort = try container.decode(UInt16.self, forKey: .localPort)
        remotePort = try container.decode(UInt16.self, forKey: .remotePort)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        source = try container.decodeIfPresent(TunnelSource.self, forKey: .source) ?? .config
        app = try container.decodeIfPresent(String.self, forKey: .app)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        forwardHost = try container.decodeIfPresent(String.self, forKey: .forwardHost) ?? "localhost"
    }
}

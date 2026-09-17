import Foundation

public enum ControlStatus: String, Codable, Sendable {
    case stopped = "stopped"
    /// Running the remote pre-step that prepares ~/.larimar.
    case preparing = "preparing"
    case connecting = "connecting"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case error = "error"

    /// Whether a connection exists or is being (re-)established.
    public var isActive: Bool {
        self != .stopped && self != .error
    }

    /// Single-glyph indicator shared by the menu and the CLI.
    public var icon: String {
        switch self {
        case .connected: return "●"
        case .preparing, .connecting, .reconnecting: return "◐"
        case .stopped: return "○"
        case .error: return "✗"
        }
    }
}

/// Status of a control connection (the ssh -R that carries the control socket).
public struct ControlInfo: Codable, Sendable {
    public let name: String
    public let sshHost: String
    public let status: ControlStatus
    public let errorMessage: String?

    public init(name: String, sshHost: String, status: ControlStatus, errorMessage: String? = nil) {
        self.name = name
        self.sshHost = sshHost
        self.status = status
        self.errorMessage = errorMessage
    }
}

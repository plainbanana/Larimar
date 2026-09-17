import Foundation

// MARK: - Request

public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let command: IPCCommand

    public init(id: String = UUID().uuidString, command: IPCCommand) {
        self.id = id
        self.command = command
    }
}

public enum IPCCommand: Codable, Sendable {
    case status
    case connect(tunnelId: String)
    case disconnect(tunnelId: String)
    case connectAll
    case disconnectAll
    case list
    /// Remove a dynamic tunnel.
    case remove(tunnelId: String)
    /// Set (or clear with nil) the hint of a tunnel.
    case setHint(tunnelId: String, hint: String?)
    case connectControl(name: String)
    case disconnectControl(name: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case tunnelId
        case hint
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "status":
            self = .status
        case "connect":
            let tunnelId = try container.decode(String.self, forKey: .tunnelId)
            self = .connect(tunnelId: tunnelId)
        case "disconnect":
            let tunnelId = try container.decode(String.self, forKey: .tunnelId)
            self = .disconnect(tunnelId: tunnelId)
        case "connectAll":
            self = .connectAll
        case "disconnectAll":
            self = .disconnectAll
        case "list":
            self = .list
        case "remove":
            self = .remove(tunnelId: try container.decode(String.self, forKey: .tunnelId))
        case "setHint":
            self = .setHint(
                tunnelId: try container.decode(String.self, forKey: .tunnelId),
                hint: try container.decodeIfPresent(String.self, forKey: .hint)
            )
        case "connectControl":
            self = .connectControl(name: try container.decode(String.self, forKey: .name))
        case "disconnectControl":
            self = .disconnectControl(name: try container.decode(String.self, forKey: .name))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.type], debugDescription: "Unknown command: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try container.encode("status", forKey: .type)
        case .connect(let tunnelId):
            try container.encode("connect", forKey: .type)
            try container.encode(tunnelId, forKey: .tunnelId)
        case .disconnect(let tunnelId):
            try container.encode("disconnect", forKey: .type)
            try container.encode(tunnelId, forKey: .tunnelId)
        case .connectAll:
            try container.encode("connectAll", forKey: .type)
        case .disconnectAll:
            try container.encode("disconnectAll", forKey: .type)
        case .list:
            try container.encode("list", forKey: .type)
        case .remove(let tunnelId):
            try container.encode("remove", forKey: .type)
            try container.encode(tunnelId, forKey: .tunnelId)
        case .setHint(let tunnelId, let hint):
            try container.encode("setHint", forKey: .type)
            try container.encode(tunnelId, forKey: .tunnelId)
            try container.encodeIfPresent(hint, forKey: .hint)
        case .connectControl(let name):
            try container.encode("connectControl", forKey: .type)
            try container.encode(name, forKey: .name)
        case .disconnectControl(let name):
            try container.encode("disconnectControl", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Response

public struct IPCResponse: Codable, Sendable {
    public let id: String
    public let success: Bool
    public let data: IPCResponseData?
    public let error: String?

    public init(id: String, success: Bool, data: IPCResponseData? = nil, error: String? = nil) {
        self.id = id
        self.success = success
        self.data = data
        self.error = error
    }

    public static func ok(id: String, data: IPCResponseData) -> IPCResponse {
        IPCResponse(id: id, success: true, data: data)
    }

    public static func fail(id: String, error: String) -> IPCResponse {
        IPCResponse(id: id, success: false, error: error)
    }
}

public struct IPCResponseData: Codable, Sendable {
    public let tunnels: [TunnelInfo]
    /// Control connection statuses; absent from older daemons.
    public let controls: [ControlInfo]?

    public init(tunnels: [TunnelInfo], controls: [ControlInfo]? = nil) {
        self.tunnels = tunnels
        self.controls = controls
    }
}

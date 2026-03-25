import Foundation

public enum TunnelStatus: String, Codable, Sendable {
    case stopped = "stopped"
    case connecting = "connecting"
    case connected = "connected"
    case reconnecting = "reconnecting"
    case error = "error"
}

public struct TunnelInfo: Codable, Sendable {
    public let id: String
    public let status: TunnelStatus
    public let mode: TunnelMode
    public let localPort: UInt16
    public let remotePort: UInt16
    public let sshHost: String
    public let errorMessage: String?

    public init(
        id: String,
        status: TunnelStatus,
        mode: TunnelMode = .local,
        localPort: UInt16,
        remotePort: UInt16,
        sshHost: String,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.mode = mode
        self.localPort = localPort
        self.remotePort = remotePort
        self.sshHost = sshHost
        self.errorMessage = errorMessage
    }

    // Backward-compatible decoding: mode defaults to .local when absent from JSON
    private enum CodingKeys: String, CodingKey {
        case id, status, mode, localPort, remotePort, sshHost, errorMessage
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
    }
}

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
    public let localPort: UInt16
    public let remotePort: UInt16
    public let sshHost: String
    public let errorMessage: String?

    public init(
        id: String,
        status: TunnelStatus,
        localPort: UInt16,
        remotePort: UInt16,
        sshHost: String,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.localPort = localPort
        self.remotePort = remotePort
        self.sshHost = sshHost
        self.errorMessage = errorMessage
    }
}

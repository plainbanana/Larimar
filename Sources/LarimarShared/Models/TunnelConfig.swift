import Foundation

public struct TunnelConfig: Codable, Sendable, Equatable {
    public let id: String
    public let localPort: UInt16
    public let remotePort: UInt16
    public let remoteHost: String
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: UInt16?
    public let bindAddress: String
    public let autoConnect: Bool
    public let autoReconnect: Bool

    public init(
        id: String,
        localPort: UInt16,
        remotePort: UInt16,
        remoteHost: String = "localhost",
        sshHost: String,
        sshUser: String? = nil,
        sshPort: UInt16? = nil,
        bindAddress: String = "127.0.0.1",
        autoConnect: Bool = false,
        autoReconnect: Bool = true
    ) {
        self.id = id
        self.localPort = localPort
        self.remotePort = remotePort
        self.remoteHost = remoteHost
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.bindAddress = bindAddress
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
    }

    /// Returns true if SSH-relevant parameters differ (requiring reconnection).
    public func sshParametersDiffer(from other: TunnelConfig) -> Bool {
        localPort != other.localPort
            || remotePort != other.remotePort
            || remoteHost != other.remoteHost
            || sshHost != other.sshHost
            || sshUser != other.sshUser
            || sshPort != other.sshPort
            || bindAddress != other.bindAddress
    }
}

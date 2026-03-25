import Foundation

public struct TunnelConfig: Codable, Sendable, Equatable {
    public let id: String
    public let mode: TunnelMode
    public let localPort: UInt16
    public let remotePort: UInt16
    public let forwardHost: String
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: UInt16?
    public let bindAddress: String
    public let autoConnect: Bool
    public let autoReconnect: Bool

    public init(
        id: String,
        mode: TunnelMode = .local,
        localPort: UInt16,
        remotePort: UInt16,
        forwardHost: String = "localhost",
        sshHost: String,
        sshUser: String? = nil,
        sshPort: UInt16? = nil,
        bindAddress: String = "127.0.0.1",
        autoConnect: Bool = false,
        autoReconnect: Bool = true
    ) {
        self.id = id
        self.mode = mode
        self.localPort = localPort
        self.remotePort = remotePort
        self.forwardHost = forwardHost
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.bindAddress = bindAddress
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
    }

    /// Returns true if SSH-relevant parameters differ (requiring reconnection).
    /// For dynamic mode, remotePort and forwardHost are not part of the SSH
    /// command and are excluded from the comparison to avoid needless reconnects.
    public func sshParametersDiffer(from other: TunnelConfig) -> Bool {
        if mode != other.mode { return true }
        if localPort != other.localPort { return true }
        if sshHost != other.sshHost { return true }
        if sshUser != other.sshUser { return true }
        if sshPort != other.sshPort { return true }
        if bindAddress != other.bindAddress { return true }
        // remotePort and forwardHost only matter for local/remote modes
        if mode != .dynamic {
            if remotePort != other.remotePort { return true }
            if forwardHost != other.forwardHost { return true }
        }
        return false
    }

    /// Returns the SSH port forwarding arguments for this tunnel's mode.
    public func sshForwardArguments() -> [String] {
        switch mode {
        case .local:
            return ["-L", "\(bindAddress):\(localPort):\(forwardHost):\(remotePort)"]
        case .remote:
            return ["-R", "\(bindAddress):\(remotePort):\(forwardHost):\(localPort)"]
        case .dynamic:
            return ["-D", "\(bindAddress):\(localPort)"]
        }
    }
}

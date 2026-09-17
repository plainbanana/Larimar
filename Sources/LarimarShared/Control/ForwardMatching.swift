import Foundation

/// Snapshot of a tunnel used to decide visibility and reuse for control requests.
public struct ForwardCandidate: Sendable, Equatable {
    public let id: String
    public let source: TunnelSource
    public let mode: TunnelMode
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: UInt16?
    public let forwardHost: String
    public let remotePort: UInt16
    public let localPort: UInt16
    public let owner: ControlOwner?
    public let isActive: Bool

    public init(
        id: String,
        source: TunnelSource,
        mode: TunnelMode,
        sshHost: String,
        sshUser: String?,
        sshPort: UInt16?,
        forwardHost: String,
        remotePort: UInt16,
        localPort: UInt16,
        owner: ControlOwner?,
        isActive: Bool
    ) {
        self.id = id
        self.source = source
        self.mode = mode
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.forwardHost = forwardHost
        self.remotePort = remotePort
        self.localPort = localPort
        self.owner = owner
        self.isActive = isActive
    }
}

public enum ForwardResolution: Sendable, Equatable {
    /// A configured local tunnel already covers the request.
    case reuseConfig(id: String)
    /// A dynamic tunnel owned by the caller already covers the request.
    case reuseDynamic(id: String)
    /// An existing dynamic tunnel conflicts with the explicit local port.
    case conflict(id: String, localPort: UInt16)
    /// Nothing matches; approval is required.
    case none
}

public enum ForwardMatcher {
    /// Whether a caller (host identity + owner) may see and operate on a tunnel.
    /// Dynamic tunnels: same owner (name and generation).
    /// Config tunnels: local mode through the same SSH identity.
    public static func isVisible(_ candidate: ForwardCandidate, identity: ControlHostIdentity, owner: ControlOwner) -> Bool {
        switch candidate.source {
        case .dynamic:
            return candidate.owner == owner
        case .config:
            return candidate.mode == .local
                && identity.matches(sshHost: candidate.sshHost, sshUser: candidate.sshUser, sshPort: candidate.sshPort)
        }
    }

    public static func resolve(
        _ request: ForwardRequest,
        candidates: [ForwardCandidate],
        identity: ControlHostIdentity,
        owner: ControlOwner
    ) -> ForwardResolution {
        let matching = candidates.filter {
            isVisible($0, identity: identity, owner: owner)
                && $0.forwardHost == request.forwardHost
                && $0.remotePort == request.remotePort
        }

        let configMatches = matching
            .filter { $0.source == .config }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.id < rhs.id
            }
        if let config = configMatches.first {
            return .reuseConfig(id: config.id)
        }

        if let dynamic = matching.filter({ $0.source == .dynamic }).min(by: { $0.id < $1.id }) {
            if let requested = request.localPort, requested != dynamic.localPort {
                return .conflict(id: dynamic.id, localPort: dynamic.localPort)
            }
            return .reuseDynamic(id: dynamic.id)
        }

        return .none
    }
}

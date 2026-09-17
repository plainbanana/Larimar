import Foundation

/// Identifies requests that can share one approval prompt. Every parameter
/// that affects the resulting forward is part of the key.
public struct ApprovalKey: Hashable, Sendable {
    public let owner: ControlOwner
    public let app: String
    public let forwardHost: String
    public let remotePort: UInt16
    public let localPort: UInt16?

    public init(owner: ControlOwner, request: ForwardRequest) {
        self.owner = owner
        self.app = request.app
        self.forwardHost = request.forwardHost
        self.remotePort = request.remotePort
        self.localPort = request.localPort
    }
}

public enum ApprovalOutcome: Sendable, Equatable {
    case allowed
    case denied
    case timedOut
    case cancelled
}

public struct PendingApproval: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let key: ApprovalKey
    public var hint: String?
    public var waiters: Set<UUID>
    public let createdAt: Date
}

public enum ApprovalSubmitResult: Sendable, Equatable {
    case created(UUID)
    case joined(UUID)
    case deniedRecently
    case limitExceeded
}

/// A recent denial that makes identical requests fail immediately until it expires or is cleared.
public struct RecentDenial: Sendable, Equatable {
    public let key: ApprovalKey
    public let hint: String?
    public let until: Date
}

/// Pure bookkeeping for pending approvals. Each pending approval resolves
/// exactly once; late resolutions are ignored.
public struct ApprovalRegistry: Sendable {
    public private(set) var pending: [UUID: PendingApproval] = [:]
    private var denials: [ApprovalKey: RecentDenial] = [:]
    public let maxPendingPerOwner: Int
    public let denyCacheDuration: TimeInterval

    public init(maxPendingPerOwner: Int = 3, denyCacheDuration: TimeInterval = 60) {
        self.maxPendingPerOwner = maxPendingPerOwner
        self.denyCacheDuration = denyCacheDuration
    }

    public mutating func submit(key: ApprovalKey, hint: String?, waiter: UUID, now: Date) -> ApprovalSubmitResult {
        pruneDenials(now: now)
        if denials[key] != nil {
            return .deniedRecently
        }

        if var existing = pending.values.first(where: { $0.key == key }) {
            existing.waiters.insert(waiter)
            if hint != nil { existing.hint = hint }
            pending[existing.id] = existing
            return .joined(existing.id)
        }

        let ownerCount = pending.values.filter { $0.key.owner == key.owner }.count
        guard ownerCount < maxPendingPerOwner else {
            return .limitExceeded
        }

        let id = UUID()
        pending[id] = PendingApproval(id: id, key: key, hint: hint, waiters: [waiter], createdAt: now)
        return .created(id)
    }

    /// Resolve a pending approval. Returns its waiters, or nil if it was already resolved.
    public mutating func resolve(_ id: UUID, outcome: ApprovalOutcome, now: Date) -> Set<UUID>? {
        guard let entry = pending.removeValue(forKey: id) else { return nil }
        if outcome == .denied {
            denials[entry.key] = RecentDenial(key: entry.key, hint: entry.hint, until: now.addingTimeInterval(denyCacheDuration))
        }
        return entry.waiters
    }

    /// Denials still in effect, oldest expiry first.
    public func recentDenials(now: Date) -> [RecentDenial] {
        denials.values.filter { $0.until > now }.sorted { $0.until < $1.until }
    }

    /// Forget a denial so the next identical request prompts again. Returns false if none existed.
    @discardableResult
    public mutating func clearDenial(_ key: ApprovalKey) -> Bool {
        denials.removeValue(forKey: key) != nil
    }

    /// Forget denials matching the predicate (e.g. the host was revoked).
    public mutating func clearDenials(where predicate: (ApprovalKey) -> Bool) {
        denials = denials.filter { !predicate($0.key) }
    }

    private mutating func pruneDenials(now: Date) {
        denials = denials.filter { $0.value.until > now }
    }

    /// Remove a single waiter (e.g. the client disconnected).
    /// Returns true when the approval was cancelled because no waiters remain.
    public mutating func removeWaiter(_ waiter: UUID, from id: UUID) -> Bool {
        guard var entry = pending[id] else { return false }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty {
            pending.removeValue(forKey: id)
            return true
        }
        pending[id] = entry
        return false
    }

    /// Cancel every pending approval matching the predicate. Returns the removed entries.
    public mutating func cancel(where predicate: (PendingApproval) -> Bool) -> [PendingApproval] {
        let removed = pending.values.filter(predicate)
        for entry in removed {
            pending.removeValue(forKey: entry.id)
        }
        return removed
    }
}

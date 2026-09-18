import AppKit
import LarimarShared
import OSLog
import SwiftUI

/// Details shown to the user when approving a forward.
struct ApprovalDetails: Equatable {
    let hostName: String
    let sshHost: String
    let request: ForwardRequest

    var localPortDescription: String {
        if let port = request.localPort {
            return String(port)
        }
        return "auto (prefers \(request.remotePort))"
    }

    var summary: String {
        "\(hostName) · \(request.app) · :\(request.remotePort)"
    }
}

enum ApprovalDecision: Equatable {
    case resolved(ApprovalOutcome)
    case deniedRecently
    case limitExceeded
    case rateLimited
}

/// Observes a client connection so a waiter can be dropped when the client goes away.
protocol DisconnectMonitoring: AnyObject {
    @MainActor func startMonitoring(onDisconnect: @escaping @MainActor () -> Void)
    @MainActor func stopMonitoring()
}

/// Presents approval prompts (floating panel + menu) and resolves waiting requests.
@MainActor
final class ApprovalCoordinator: ObservableObject {
    struct PendingItem: Identifiable, Equatable {
        let id: UUID
        let details: ApprovalDetails
        /// Latest hint; a joining request may update it after the details were captured.
        let hint: String?
    }

    struct DeniedItem: Identifiable, Equatable {
        let key: ApprovalKey
        let details: ApprovalDetails
        let hint: String?
        let until: Date

        var id: ApprovalKey { key }
    }

    @Published private(set) var pendingItems: [PendingItem] = []
    @Published private(set) var deniedItems: [DeniedItem] = []

    var timeout: TimeInterval = TimeInterval(ControlConfig.defaultApprovalTimeout)

    private var registry = ApprovalRegistry()
    private var details: [UUID: ApprovalDetails] = [:]
    private var deniedDetails: [ApprovalKey: ApprovalDetails] = [:]
    private var denialExpiryTask: Task<Void, Never>?
    private var continuations: [UUID: CheckedContinuation<ApprovalOutcome, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var panels: [UUID: ApprovalPanelController] = [:]
    private var isShuttingDown = false

    func requestApproval(owner: ControlOwner, details: ApprovalDetails, monitor: DisconnectMonitoring) async -> ApprovalDecision {
        guard !isShuttingDown else { return .resolved(.cancelled) }

        let key = ApprovalKey(owner: owner, request: details.request)
        let waiter = UUID()
        let pendingId: UUID

        switch registry.submit(key: key, hint: details.request.hint, waiter: waiter, now: Date()) {
        case .deniedRecently:
            Log.control.notice("Approval rejected: recently denied")
            return .deniedRecently
        case .limitExceeded:
            Log.control.notice("Approval rejected: too many pending requests")
            return .limitExceeded
        case .rateLimited:
            Log.control.notice("Approval rejected: too many prompts recently")
            return .rateLimited
        case .joined(let id):
            pendingId = id
        case .created(let id):
            pendingId = id
            self.details[id] = details
            scheduleTimeout(id)
            showPanel(id, details: details)
            publish()
            Log.control.info("Approval requested for owner=\(owner.name, privacy: .private(mask: .hash))")
        }

        monitor.startMonitoring { [weak self] in
            self?.waiterLeft(waiter, pendingId: pendingId)
        }
        let outcome = await withCheckedContinuation { continuation in
            continuations[waiter] = continuation
        }
        monitor.stopMonitoring()

        return .resolved(outcome)
    }

    func allow(_ id: UUID) {
        resolve(id, outcome: .allowed)
    }

    func deny(_ id: UUID) {
        resolve(id, outcome: .denied)
    }

    /// Forget a denial so the next identical request shows a prompt again.
    func clearDenial(_ key: ApprovalKey) {
        guard registry.clearDenial(key) else { return }
        deniedDetails.removeValue(forKey: key)
        Log.control.info("Denial cleared")
        publish()
    }

    /// Cancel pending approvals and forget denials for owners matching the predicate (host removed or changed).
    func cancelAll(where predicate: (ControlOwner) -> Bool) {
        let removed = registry.cancel { predicate($0.key.owner) }
        for entry in removed {
            Log.control.info("Approval cancelled (host revoked)")
            finish(entry.id, waiters: entry.waiters, outcome: .cancelled)
        }
        registry.clearDenials { predicate($0.owner) }
        deniedDetails = deniedDetails.filter { !predicate($0.key.owner) }
        publish()
    }

    func shutdown() {
        isShuttingDown = true
        cancelAll { _ in true }
    }

    // MARK: - Private

    private func resolve(_ id: UUID, outcome: ApprovalOutcome) {
        let key = registry.pending[id]?.key
        guard let waiters = registry.resolve(id, outcome: outcome, now: Date()) else { return }
        if outcome == .denied, let key, let captured = details[id] {
            deniedDetails[key] = captured
        }
        Log.control.info("Approval resolved: \(String(describing: outcome), privacy: .public)")
        finish(id, waiters: waiters, outcome: outcome)
        publish()
    }

    private func waiterLeft(_ waiter: UUID, pendingId: UUID) {
        guard let continuation = continuations.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: .cancelled)
        if registry.removeWaiter(waiter, from: pendingId) {
            Log.control.info("Approval cancelled (all clients disconnected)")
            finish(pendingId, waiters: [], outcome: .cancelled)
            publish()
        }
    }

    private func finish(_ id: UUID, waiters: Set<UUID>, outcome: ApprovalOutcome) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        details.removeValue(forKey: id)
        panels.removeValue(forKey: id)?.close()
        for waiter in waiters {
            continuations.removeValue(forKey: waiter)?.resume(returning: outcome)
        }
    }

    private func scheduleTimeout(_ id: UUID) {
        let seconds = timeout
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(id, outcome: .timedOut)
        }
    }

    private func showPanel(_ id: UUID, details: ApprovalDetails) {
        let controller = ApprovalPanelController(
            details: details,
            onAllow: { [weak self] in self?.allow(id) },
            onDeny: { [weak self] in self?.deny(id) }
        )
        panels[id] = controller
        controller.show()
    }

    private func publish() {
        pendingItems = registry.pending.values
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { entry in
                details[entry.id].map { PendingItem(id: entry.id, details: $0, hint: entry.hint) }
            }

        let now = Date()
        let denials = registry.recentDenials(now: now)
        deniedDetails = deniedDetails.filter { key, _ in denials.contains { $0.key == key } }
        deniedItems = denials.compactMap { denial in
            deniedDetails[denial.key].map { DeniedItem(key: denial.key, details: $0, hint: denial.hint, until: denial.until) }
        }

        // Republish when the earliest denial expires so the menu drops it
        denialExpiryTask?.cancel()
        if let next = denials.first?.until {
            denialExpiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, next.timeIntervalSinceNow) * 1_000_000_000) + 100_000_000)
                guard !Task.isCancelled else { return }
                self?.publish()
            }
        }
    }
}

// MARK: - Panel

/// Non-modal floating panel asking the user to allow or deny a forward.
/// Closing the panel counts as deny.
@MainActor
final class ApprovalPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let onDeny: () -> Void
    private var closedProgrammatically = false

    init(details: ApprovalDetails, onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
        self.onDeny = onDeny
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Larimar: Forward Request"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // Stay visible while the user works in another app; the request may
        // arrive at any time and must not vanish when Larimar loses focus.
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ApprovalView(details: details, onAllow: onAllow, onDeny: onDeny))
        panel.center()
    }

    /// Show the panel without activating Larimar: a remote host must not be able
    /// to steal the keyboard focus from whatever the user is doing.
    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        closedProgrammatically = true
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closedProgrammatically {
            onDeny()
        }
    }
}

private struct ApprovalView: View {
    let details: ApprovalDetails
    let onAllow: () -> Void
    let onDeny: () -> Void

    /// Allow stays disabled briefly after the panel appears so a click or key
    /// press meant for another window cannot approve a request by accident.
    @State private var allowArmed = false
    static let allowDelay: Duration = .seconds(1)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A remote host requests a new port forward.")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Host", "\(details.hostName) (\(details.sshHost))")
                row("App", details.request.app)
                row("Remote", "\(details.request.forwardHost):\(details.request.remotePort)")
                row("Local port", details.localPortDescription)
                if let hint = details.request.hint {
                    row("Hint", hint)
                }
            }
            HStack {
                Spacer()
                Button("Deny", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: onAllow)
                    .disabled(!allowArmed)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            try? await Task.sleep(for: Self.allowDelay)
            allowArmed = true
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

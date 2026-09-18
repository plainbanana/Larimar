import Foundation
import LarimarShared
import OSLog

/// Serves the v1 HTTP API on per-host control sockets. The socket a request
/// arrives on determines which allowed host (and generation) sent it.
@MainActor
final class ControlServer {
    private let tunnelManager: TunnelManager
    private let controlConnections: ControlConnectionManager
    private let approvals: ApprovalCoordinator

    private struct HostEndpoint {
        let identity: ControlHostIdentity
        let owner: ControlOwner
        let listener: UnixSocketListener
        var activeConnections = 0
    }

    private var endpoints: [String: HostEndpoint] = [:]
    private var nextGeneration: UInt64 = 1
    private var totalConnections = 0
    private var isShuttingDown = false

    static let maxConnectionsPerHost = 8
    static let maxConnectionsTotal = 32
    nonisolated static let readTimeout: TimeInterval = 5

    init(tunnelManager: TunnelManager, controlConnections: ControlConnectionManager, approvals: ApprovalCoordinator) {
        self.tunnelManager = tunnelManager
        self.controlConnections = controlConnections
        self.approvals = approvals
    }

    // MARK: - Configuration

    /// Apply control configuration. Hosts that were removed or whose SSH
    /// identity changed are revoked; new hosts get a fresh generation.
    func apply(_ config: ControlConfig, sshAuthSock: String?) {
        guard !isShuttingDown else { return }
        controlConnections.updateAuthSock(sshAuthSock)
        approvals.timeout = TimeInterval(config.approvalTimeout)

        let desired: [String: ControlHost] = config.enabled
            ? Dictionary(uniqueKeysWithValues: config.hosts.map { ($0.name, $0) })
            : [:]

        for (name, endpoint) in endpoints where desired[name]?.identity != endpoint.identity {
            revoke(name: name)
        }
        // Hosts that previously failed to start have no endpoint but may have a connection row
        for name in controlConnections.connections.keys where endpoints[name] == nil {
            controlConnections.remove(name: name)
        }

        for host in desired.values.sorted(by: { $0.name < $1.name }) where endpoints[host.name] == nil {
            addHost(host)
        }
    }

    func stop() {
        isShuttingDown = true
        for name in Array(endpoints.keys) {
            endpoints[name]?.listener.stop()
        }
        endpoints.removeAll()
    }

    private func addHost(_ host: ControlHost) {
        let identity = host.identity
        let generation = nextGeneration
        nextGeneration += 1
        let owner = ControlOwner(name: host.name, generation: generation)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(ControlPaths.macSocketDirectoryName).path
        let path = (dir as NSString).appendingPathComponent(ControlPaths.macSocketFileName(identity: identity, generation: generation))
        guard ControlPaths.isSafeSocketPath(path) else {
            Log.control.error("Mac control socket path unsupported for \(host.name, privacy: .private(mask: .hash))")
            controlConnections.addFailed(identity: identity, message: "Unsupported Mac socket path: \(path)")
            return
        }

        let listener = UnixSocketListener(path: path)
        do {
            try listener.start { [weak self] fd in
                self?.accept(fd: fd, owner: owner)
            }
        } catch {
            Log.control.error("Control listener failed for \(host.name, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
            controlConnections.addFailed(identity: identity, message: "Control socket failed: \(error.localizedDescription)")
            return
        }

        endpoints[host.name] = HostEndpoint(identity: identity, owner: owner, listener: listener)
        Log.control.info("Control listener started for \(host.name, privacy: .private(mask: .hash)), generation=\(generation)")
        controlConnections.add(identity: identity, macSocketPath: path, autoConnect: host.autoConnect)
    }

    private func revoke(name: String) {
        guard let endpoint = endpoints.removeValue(forKey: name) else { return }
        Log.control.info("Revoking control host \(name, privacy: .private(mask: .hash)), generation=\(endpoint.owner.generation)")
        endpoint.listener.stop()
        approvals.cancelAll { $0 == endpoint.owner }
        tunnelManager.removeDynamics { $0 == endpoint.owner }
        controlConnections.remove(name: name)
    }

    /// Whether the owner still refers to the current incarnation of its host.
    private func currentEndpoint(for owner: ControlOwner) -> HostEndpoint? {
        guard !isShuttingDown, let endpoint = endpoints[owner.name], endpoint.owner == owner else { return nil }
        return endpoint
    }

    // MARK: - Connections

    private func accept(fd: Int32, owner: ControlOwner) {
        guard currentEndpoint(for: owner) != nil,
              totalConnections < Self.maxConnectionsTotal,
              (endpoints[owner.name]?.activeConnections ?? 0) < Self.maxConnectionsPerHost else {
            Log.control.notice("Control connection rejected: limit reached or host revoked")
            let response = ControlAPIError.busy.response.serialized()
            DispatchQueue.global().async {
                SocketIO.writeAll(fd: fd, data: response)
                close(fd)
            }
            return
        }

        totalConnections += 1
        endpoints[owner.name]?.activeConnections += 1
        let connection = ClientConnection(fd: fd)

        DispatchQueue.global().async { [weak self] in
            let result = Self.readRequest(fd: fd)
            Task { @MainActor [weak self] in
                guard let self else {
                    close(fd)
                    return
                }
                let response: HTTPResponse
                switch result {
                case .complete(let request):
                    response = await self.handle(request, owner: owner, connection: connection)
                case .failure(let status, let message):
                    Log.control.notice("Rejected malformed control request: status=\(status)")
                    response = .error(status, code: "bad_request", message: message)
                case .incomplete:
                    response = ControlAPIError.requestTimeout.response
                }
                connection.stopMonitoring()
                let data = response.serialized()
                DispatchQueue.global().async {
                    SocketIO.writeAll(fd: fd, data: data)
                    close(fd)
                    Task { @MainActor [weak self] in
                        self?.connectionClosed(owner: owner)
                    }
                }
            }
        }
    }

    private func connectionClosed(owner: ControlOwner) {
        totalConnections -= 1
        if let endpoint = endpoints[owner.name], endpoint.owner == owner {
            endpoints[owner.name]?.activeConnections -= 1
        }
    }

    /// Read one request with an overall deadline and size limits.
    private nonisolated static func readRequest(fd: Int32) -> HTTPParseResult {
        let limits = HTTPLimits.default
        let deadline = Date().addingTimeInterval(readTimeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .incomplete }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(status: 400, message: "read error")
            }
            if ready == 0 { return .incomplete }

            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(status: 400, message: "read error")
            }
            if n == 0 {
                let result = HTTPRequestParser.parse(buffer, limits: limits)
                return result == .incomplete ? .failure(status: 400, message: "incomplete request") : result
            }
            buffer.append(contentsOf: chunk[..<n])

            let result = HTTPRequestParser.parse(buffer, limits: limits)
            if result != .incomplete {
                return result
            }
            if buffer.count > limits.maxTotalBytes {
                return .failure(status: 413, message: "request too large")
            }
        }
    }

    // MARK: - API

    private func handle(_ request: HTTPRequest, owner: ControlOwner, connection: ClientConnection) async -> HTTPResponse {
        do {
            return try await route(request, owner: owner, connection: connection)
        } catch let error as ControlAPIError {
            return error.response
        } catch {
            return .error(500, code: "internal_error", message: "internal error")
        }
    }

    private func route(_ request: HTTPRequest, owner: ControlOwner, connection: ClientConnection) async throws -> HTTPResponse {
        guard let endpoint = currentEndpoint(for: owner) else { throw ControlAPIError.hostRevoked }

        let route = try ControlRoute.resolve(method: request.method, path: request.path).get()
        if route.requiresJSONBody, let error = ControlValidation.requireJSON(request) {
            throw error
        }

        switch route {
        case .health:
            return .json(200, HealthView(version: LarimarVersion.current, host: owner.name))

        case .listForwards:
            let views = visibleInfos(endpoint: endpoint).map(ForwardView.init(info:))
            return .json(200, ForwardListView(forwards: views))

        case .getForward(let id):
            return .json(200, ForwardView(info: try visibleInfo(id: id, endpoint: endpoint)))

        case .deleteForward(let id):
            let info = try visibleInfo(id: id, endpoint: endpoint)
            if info.source == .dynamic {
                tunnelManager.removeDynamic(tunnelId: id)
            } else {
                tunnelManager.setHint(tunnelId: id, hint: nil)
            }
            return .json(200, ForwardView(info: info))

        case .setHint(let id):
            _ = try visibleInfo(id: id, endpoint: endpoint)
            let hint = try ControlValidation.decode(HintBody.self, from: request.body)
                .flatMap { ControlValidation.sanitizeHint($0.hint) }
                .get()
            tunnelManager.setHint(tunnelId: id, hint: hint)
            return try forwardResponse(200, id: id)

        case .clearHint(let id):
            _ = try visibleInfo(id: id, endpoint: endpoint)
            tunnelManager.setHint(tunnelId: id, hint: nil)
            return try forwardResponse(200, id: id)

        case .createForward:
            let forward = try ControlValidation.decode(CreateForwardBody.self, from: request.body)
                .flatMap(ControlValidation.validateCreate)
                .get()
            return try await createForward(forward, endpoint: endpoint, connection: connection)
        }
    }

    private func createForward(_ forward: ForwardRequest, endpoint: HostEndpoint, connection: ClientConnection) async throws -> HTTPResponse {
        if let response = try reuseExisting(forward, endpoint: endpoint) {
            return response
        }

        let details = ApprovalDetails(hostName: endpoint.identity.name, sshHost: endpoint.identity.sshHost, request: forward)
        switch await approvals.requestApproval(owner: endpoint.owner, details: details, monitor: connection) {
        case .resolved(.allowed):
            break
        case .resolved(.denied):
            throw ControlAPIError.denied
        case .deniedRecently:
            throw ControlAPIError.recentlyDenied
        case .resolved(.timedOut):
            throw ControlAPIError.approvalTimeout
        case .resolved(.cancelled):
            throw ControlAPIError.cancelled
        case .limitExceeded:
            throw ControlAPIError.tooManyPending
        case .rateLimited:
            throw ControlAPIError.rateLimited
        }

        // Re-validate: the host may have been revoked or the forward created meanwhile
        guard let current = currentEndpoint(for: endpoint.owner) else { throw ControlAPIError.hostRevoked }
        if let response = try reuseExisting(forward, endpoint: current) {
            return response
        }

        let allocated = tunnelManager.allocatedLocalPorts()
        let localPort: UInt16
        if let requested = forward.localPort {
            guard LocalPortAllocator.isAvailable(requested, allocated: allocated) else {
                throw ControlAPIError.localPortInUse(requested)
            }
            localPort = requested
        } else {
            guard let port = LocalPortAllocator.allocate(preferred: forward.remotePort, allocated: allocated) else {
                throw ControlAPIError.noLocalPort
            }
            localPort = port
        }

        guard let id = tunnelManager.addDynamic(owner: current.owner, identity: current.identity, request: forward, localPort: localPort) else {
            throw ControlAPIError.shuttingDown
        }
        return try forwardResponse(201, id: id)
    }

    /// Returns a response when an existing tunnel covers the request, or nil when approval is needed.
    private func reuseExisting(_ forward: ForwardRequest, endpoint: HostEndpoint) throws -> HTTPResponse? {
        switch ForwardMatcher.resolve(forward, candidates: tunnelManager.forwardCandidates(), identity: endpoint.identity, owner: endpoint.owner) {
        case .reuseConfig(let id), .reuseDynamic(let id):
            if let hint = forward.hint {
                tunnelManager.setHint(tunnelId: id, hint: hint)
            }
            if tunnelManager.tunnelStates[id]?.isActive == false {
                tunnelManager.connect(tunnelId: id)
            }
            return try forwardResponse(200, id: id)
        case .conflict(let id, let port):
            throw ControlAPIError.localPortConflict(id: id, port: port)
        case .none:
            return nil
        }
    }

    private func forwardResponse(_ status: Int, id: String) throws -> HTTPResponse {
        guard let info = tunnelManager.tunnelInfo(id: id) else { throw ControlAPIError.notFound }
        return .json(status, ForwardView(info: info))
    }

    private func isVisible(_ candidate: ForwardCandidate, to endpoint: HostEndpoint) -> Bool {
        ForwardMatcher.isVisible(candidate, identity: endpoint.identity, owner: endpoint.owner)
    }

    private func visibleInfos(endpoint: HostEndpoint) -> [TunnelInfo] {
        let visibleIds = Set(tunnelManager.forwardCandidates().filter { isVisible($0, to: endpoint) }.map(\.id))
        return tunnelManager.tunnelInfos().filter { visibleIds.contains($0.id) }
    }

    private func visibleInfo(id: String, endpoint: HostEndpoint) throws -> TunnelInfo {
        guard let candidate = tunnelManager.forwardCandidate(id: id), isVisible(candidate, to: endpoint),
              let info = tunnelManager.tunnelInfo(id: id) else { throw ControlAPIError.notFound }
        return info
    }
}

// MARK: - Client Connection

/// Watches a client socket for EOF while its request waits for approval.
@MainActor
final class ClientConnection: DisconnectMonitoring {
    private let fd: Int32
    private var source: DispatchSourceRead?

    init(fd: Int32) {
        self.fd = fd
    }

    func startMonitoring(onDisconnect: @escaping @MainActor () -> Void) {
        stopMonitoring()
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            // Discard unexpected extra bytes; EOF or an error means the client left
            let n = read(fd, &buffer, buffer.count)
            if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) {
                MainActor.assumeIsolated {
                    self?.stopMonitoring()
                    onDisconnect()
                }
            }
        }
        self.source = source
        source.resume()
    }

    func stopMonitoring() {
        source?.cancel()
        source = nil
    }
}

// MARK: - Local Port Allocation

enum LocalPortAllocator {
    /// A port is available when no tunnel uses it and it can be bound on 127.0.0.1.
    static func isAvailable(_ port: UInt16, allocated: Set<UInt16>) -> Bool {
        !allocated.contains(port) && canBind(port)
    }

    static func allocate(preferred: UInt16, allocated: Set<UInt16>) -> UInt16? {
        if isAvailable(preferred, allocated: allocated) {
            return preferred
        }
        for _ in 0..<16 {
            if let port = ephemeralPort(), !allocated.contains(port) {
                return port
            }
        }
        return nil
    }

    private static func canBind(_ port: UInt16) -> Bool {
        withLoopbackSocket(port: port) { _ in true } ?? false
    }

    private static func ephemeralPort() -> UInt16? {
        withLoopbackSocket(port: 0) { fd in
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            return result == 0 ? UInt16(bigEndian: addr.sin_port) : nil
        } ?? nil
    }

    private static func withLoopbackSocket<T>(port: UInt16, _ body: (Int32) -> T) -> T? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? body(fd) : nil
    }
}

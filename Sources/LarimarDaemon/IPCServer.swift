import Foundation
import LarimarShared
import OSLog

/// Unix domain socket server for IPC with CLI clients.
/// Protocol: one JSON request per connection, one JSON response back, then close.
@MainActor
final class IPCServer {
    private var listener: UnixSocketListener?
    private let tunnelManager: TunnelManager
    private let controlConnections: ControlConnectionManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(tunnelManager: TunnelManager, controlConnections: ControlConnectionManager) {
        self.tunnelManager = tunnelManager
        self.controlConnections = controlConnections
    }

    func start() throws {
        let listener = UnixSocketListener(path: LarimarConstants.socketPath)
        try listener.start { [weak self] clientFd in
            self?.handleConnection(clientFd)
        }
        self.listener = listener
        Log.ipc.info("IPC server listening")
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ clientFd: Int32) {
        DispatchQueue.global().async { [weak self] in
            defer { close(clientFd) }

            // Read one message (until newline or EOF, max 64KB)
            guard let requestData = Self.readMessage(fd: clientFd) else { return }
            guard let self else { return }

            let responseData = DispatchQueue.main.sync {
                self.processRequest(requestData)
            }

            var payload = responseData
            payload.append(UInt8(ascii: "\n"))
            SocketIO.writeAll(fd: clientFd, data: payload)
        }
    }

    /// Read from fd until newline or EOF, retrying on EINTR. Returns nil on error or empty read.
    private nonisolated static func readMessage(fd: Int32, maxSize: Int = 65536) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buffer.count < maxSize {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[..<n])
                // Stop at first newline
                if buffer.contains(UInt8(ascii: "\n")) {
                    break
                }
            } else if n == 0 {
                // EOF — use whatever we have
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }

        if buffer.count > maxSize {
            return nil // message too large
        }

        // Trim trailing newline
        if let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            return Data(buffer[..<idx])
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func processRequest(_ data: Data) -> Data {
        do {
            let request = try decoder.decode(IPCRequest.self, from: data)
            let response = handleCommand(request)
            return try encoder.encode(response)
        } catch {
            Log.ipc.notice("Invalid IPC request: \(error, privacy: .private)")
            let errorResponse = IPCResponse.fail(id: "unknown", error: "Invalid request: \(error.localizedDescription)")
            return (try? encoder.encode(errorResponse)) ?? Data()
        }
    }

    private func handleCommand(_ request: IPCRequest) -> IPCResponse {
        switch request.command {
        case .status, .list:
            return ok(request)

        case .connect(let tunnelId):
            guard tunnelManager.tunnelStates[tunnelId] != nil else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            tunnelManager.connect(tunnelId: tunnelId)
            return ok(request)

        case .disconnect(let tunnelId):
            guard tunnelManager.tunnelStates[tunnelId] != nil else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            tunnelManager.disconnect(tunnelId: tunnelId)
            return ok(request)

        case .connectAll:
            tunnelManager.connectAll()
            return ok(request)

        case .disconnectAll:
            tunnelManager.disconnectAll()
            return ok(request)

        case .remove(let tunnelId):
            guard let entry = tunnelManager.tunnelStates[tunnelId] else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            guard entry.source == .dynamic else {
                return .fail(id: request.id, error: "Only dynamic tunnels can be removed; edit tunnels.toml for '\(tunnelId)'")
            }
            tunnelManager.removeDynamic(tunnelId: tunnelId)
            return ok(request)

        case .setHint(let tunnelId, let hint):
            guard tunnelManager.tunnelStates[tunnelId] != nil else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            switch ControlValidation.sanitizeHint(hint ?? "") {
            case .success(let sanitized):
                tunnelManager.setHint(tunnelId: tunnelId, hint: sanitized)
                return ok(request)
            case .failure(let error):
                return .fail(id: request.id, error: error.message)
            }

        case .connectControl(let name), .disconnectControl(let name):
            guard controlConnections.connections[name] != nil else {
                return .fail(id: request.id, error: "Unknown control host: \(name)")
            }
            if case .connectControl = request.command {
                controlConnections.connect(name: name)
            } else {
                controlConnections.disconnect(name: name)
            }
            return ok(request)
        }
    }

    private func ok(_ request: IPCRequest) -> IPCResponse {
        .ok(id: request.id, data: IPCResponseData(
            tunnels: tunnelManager.tunnelInfos(),
            controls: controlConnections.controlInfos()
        ))
    }
}

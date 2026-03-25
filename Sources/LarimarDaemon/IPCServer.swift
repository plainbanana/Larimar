import Foundation
import LarimarShared
import OSLog

/// Unix domain socket server for IPC with CLI clients.
/// Protocol: one JSON request per connection, one JSON response back, then close.
@MainActor
final class IPCServer {
    var listener: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let tunnelManager: TunnelManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(tunnelManager: TunnelManager) {
        self.tunnelManager = tunnelManager
    }

    func start() throws {
        let socketPath = LarimarConstants.socketPath

        // Ensure parent directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed
        }

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw IPCError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw IPCError.bindFailed(errno)
        }

        // Set socket permissions (owner read/write only)
        chmod(socketPath, 0o600)

        // Listen
        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            throw IPCError.listenFailed(errno)
        }

        self.listener = fd

        // Use GCD to accept connections
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.listenSource = source
        source.resume()
        Log.ipc.info("IPC server listening")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if listener >= 0 {
            listener = -1
        }
        try? FileManager.default.removeItem(atPath: LarimarConstants.socketPath)
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let clientFd = accept(listener, nil, nil)
        guard clientFd >= 0 else { return }

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
            Self.writeAll(fd: clientFd, data: payload)
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

    /// Write all bytes to fd, retrying on EINTR and short writes.
    @discardableResult
    private nonisolated static func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data[...]
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, ptr.count)
            }
            if n > 0 {
                remaining = remaining.dropFirst(n)
            } else if n == 0 {
                return false
            } else if errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
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
        case .status:
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))

        case .connect(let tunnelId):
            guard tunnelManager.tunnelStates[tunnelId] != nil else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            tunnelManager.connect(tunnelId: tunnelId)
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))

        case .disconnect(let tunnelId):
            guard tunnelManager.tunnelStates[tunnelId] != nil else {
                return .fail(id: request.id, error: "Unknown tunnel: \(tunnelId)")
            }
            tunnelManager.disconnect(tunnelId: tunnelId)
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))

        case .connectAll:
            tunnelManager.connectAll()
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))

        case .disconnectAll:
            tunnelManager.disconnectAll()
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))

        case .list:
            return .ok(id: request.id, data: IPCResponseData(tunnels: tunnelManager.tunnelInfos()))
        }
    }

    enum IPCError: Error {
        case socketCreationFailed
        case pathTooLong
        case bindFailed(Int32)
        case listenFailed(Int32)
    }
}

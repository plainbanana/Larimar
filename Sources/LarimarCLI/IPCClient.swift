import Foundation
import LarimarShared

/// Connects to the LarimarDaemon via Unix domain socket.
/// Protocol: one JSON request per connection, one JSON response back, then close.
enum IPCClient {
    enum IPCError: Error, CustomStringConvertible {
        case connectionFailed(String)
        case timeout
        case invalidResponse
        case messageTooLarge

        var description: String {
            switch self {
            case .connectionFailed(let msg): return "Connection failed: \(msg)"
            case .timeout: return "Request timed out"
            case .invalidResponse: return "Invalid response from daemon"
            case .messageTooLarge: return "Response exceeded maximum size"
            }
        }
    }

    static func send(_ command: IPCCommand) async throws -> IPCResponse {
        let socketPath = LarimarConstants.socketPath

        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw IPCError.connectionFailed("Daemon not running (socket not found at \(socketPath))")
        }

        let request = IPCRequest(command: command)
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.connectionFailed("Failed to create socket")
        }
        defer { close(fd) }

        // Set send/receive timeout (10 seconds)
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let pathBytes = socketPath.utf8CString
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed("Cannot connect to daemon (errno: \(errno))")
        }

        // Send request with writeAll (handles EINTR and short writes)
        guard writeAll(fd: fd, data: payload) else {
            throw IPCError.connectionFailed("Failed to send request")
        }

        // Read response (handles EINTR, EOF, overflow)
        let responseData = try readMessage(fd: fd)
        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }

    /// Read from fd until newline or EOF, retrying on EINTR.
    private static func readMessage(fd: Int32, maxSize: Int = 65536) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buffer.count < maxSize {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[..<n])
                if buffer.contains(UInt8(ascii: "\n")) { break }
            } else if n == 0 {
                break // EOF
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IPCError.timeout
            } else {
                throw IPCError.invalidResponse
            }
        }

        if buffer.count > maxSize {
            throw IPCError.messageTooLarge
        }

        // Trim trailing newline
        if let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            return Data(buffer[..<idx])
        }
        guard !buffer.isEmpty else { throw IPCError.invalidResponse }
        return buffer
    }

    /// Write all bytes to fd, retrying on EINTR and short writes.
    private static func writeAll(fd: Int32, data: Data) -> Bool {
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
}

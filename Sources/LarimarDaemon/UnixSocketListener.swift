import Foundation
import OSLog

/// Listening Unix domain socket in an owner-only directory.
/// The directory is verified (not a symlink, owned by the user, mode 0700)
/// and the socket is chmod 0600 before listening.
@MainActor
final class UnixSocketListener {
    let path: String
    private var listenSource: DispatchSourceRead?

    init(path: String) {
        self.path = path
    }

    func start(onAccept: @escaping (Int32) -> Void) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try Self.preparePrivateDirectory(dir)
        try Self.removeStaleSocket(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ListenerError.socketCreationFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ListenerError.pathTooLong
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
            let err = errno
            close(fd)
            throw ListenerError.bindFailed(err)
        }

        guard chmod(path, 0o600) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ListenerError.chmodFailed(err)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw ListenerError.listenFailed(err)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            let clientFd = accept(fd, nil, nil)
            guard clientFd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            onAccept(clientFd)
        }
        source.setCancelHandler {
            close(fd)
        }
        listenSource = source
        source.resume()
    }

    func stop() {
        guard let source = listenSource else { return }
        source.cancel()
        listenSource = nil
        try? Self.removeStaleSocket(path)
    }

    /// Create the directory if needed and verify it is a private directory owned by the user.
    static func preparePrivateDirectory(_ dir: String) throws {
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var st = stat()
        guard lstat(dir, &st) == 0 else {
            throw ListenerError.directoryCheckFailed(dir, "lstat failed (errno \(errno))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw ListenerError.directoryCheckFailed(dir, "not a directory or is a symlink")
        }
        guard st.st_uid == getuid() else {
            throw ListenerError.directoryCheckFailed(dir, "not owned by the current user")
        }
        guard chmod(dir, 0o700) == 0 else {
            throw ListenerError.directoryCheckFailed(dir, "chmod failed (errno \(errno))")
        }
    }

    /// Remove a leftover socket file. Refuses to delete anything that is not a socket.
    static func removeStaleSocket(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw ListenerError.notASocket(path)
        }
        unlink(path)
    }

    enum ListenerError: LocalizedError {
        case socketCreationFailed(Int32)
        case pathTooLong
        case bindFailed(Int32)
        case chmodFailed(Int32)
        case listenFailed(Int32)
        case directoryCheckFailed(String, String)
        case notASocket(String)

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed(let e): return "socket() failed (errno \(e))"
            case .pathTooLong: return "socket path too long"
            case .bindFailed(let e): return "bind() failed (errno \(e))"
            case .chmodFailed(let e): return "chmod() on socket failed (errno \(e))"
            case .listenFailed(let e): return "listen() failed (errno \(e))"
            case .directoryCheckFailed(let dir, let reason): return "\(dir): \(reason)"
            case .notASocket(let path): return "\(path) exists and is not a socket"
            }
        }
    }
}

enum SocketIO {
    /// Write all bytes to fd, retrying on EINTR and short writes, and give up
    /// once `timeout` has passed so a peer that stops reading cannot hold the
    /// connection (and its slot) forever. Leaves the fd non-blocking.
    @discardableResult
    static func writeAll(fd: Int32, data: Data, timeout: TimeInterval = 5) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var remaining = data[...]
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                remaining = remaining.dropFirst(n)
                continue
            }
            guard n < 0 else { return false }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                let ms = deadline.timeIntervalSinceNow * 1000
                guard ms > 0 else { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, Int32(ms))
                if ready == 0 || (ready < 0 && errno != EINTR) { return false }
            default:
                return false
            }
        }
        return true
    }
}

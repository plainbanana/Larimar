import Foundation

/// Builds ssh command lines for processes Larimar owns.
public enum SSHCommand {
    public static let executablePath = "/usr/bin/ssh"

    /// Environment for a managed ssh: inherit the parent, optionally override SSH_AUTH_SOCK.
    public static func environment(authSock: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let sock = authSock {
            env["SSH_AUTH_SOCK"] = NSString(string: sock).expandingTildeInPath
        }
        return env
    }

    /// Trimmed stderr text, or nil when ssh printed nothing.
    /// Keeps the tail; ssh may print banners before the actual error.
    public static func errorMessage(stderr: Data) -> String? {
        guard let text = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return String(text.suffix(500))
    }

    /// Keep every managed ssh a single foreground process so terminating it
    /// reliably tears down its forwards (no multiplexing, no backgrounding).
    public static let ownershipOptions = [
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "ForkAfterAuthentication=no",
    ]

    /// Printed to stdout by ssh's LocalCommand, which runs only once authentication
    /// has succeeded. A live process alone is not proof: ssh may still be waiting
    /// on the agent (e.g. a 1Password approval prompt).
    public static let readyMarker = "larimar-ready"

    /// Call `onReady` once when the ssh writing to `stdout` reports it is authenticated.
    /// The handler runs on a background queue.
    public static func watchReady(stdout: Pipe, onReady: @escaping @Sendable () -> Void) {
        let marker = Data(readyMarker.utf8)
        let buffer = LockedData()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // LocalCommand output is tiny; keep only enough to match a split marker
            if buffer.appendAndCheck(chunk, marker: marker) {
                handle.readabilityHandler = nil
                onReady()
            }
        }
    }

    /// Arguments for a long-running forwarding process (`ssh -N ...`).
    public static func forwardingArguments(forward: [String], sshHost: String, sshUser: String?, sshPort: UInt16?) -> [String] {
        var args = ["-N"]
        args += forward
        args += ownershipOptions
        args += ["-o", "ServerAliveInterval=15"]
        args += ["-o", "ServerAliveCountMax=3"]
        args += ["-o", "ExitOnForwardFailure=yes"]
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "PermitLocalCommand=yes"]
        args += ["-o", "LocalCommand=echo \(readyMarker)"]
        args += connectionArguments(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort)
        return args
    }

    /// Arguments for the control pre-step (`ssh host sh -s`, script on stdin).
    public static func prepArguments(identity: ControlHostIdentity) -> [String] {
        var args = ownershipOptions
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "ConnectTimeout=10"]
        args += ["-T"]
        args += connectionArguments(sshHost: identity.sshHost, sshUser: identity.sshUser, sshPort: identity.sshPort)
        args += ["sh", "-s"]
        return args
    }

    /// Arguments for the control connection that forwards the remote socket to the Mac socket.
    public static func controlArguments(identity: ControlHostIdentity, remoteSocket: String, macSocket: String) -> [String] {
        forwardingArguments(
            forward: ["-R", "\(remoteSocket):\(macSocket)"],
            sshHost: identity.sshHost,
            sshUser: identity.sshUser,
            sshPort: identity.sshPort
        )
    }

    private static func connectionArguments(sshHost: String, sshUser: String?, sshPort: UInt16?) -> [String] {
        var args: [String] = []
        if let user = sshUser {
            args += ["-l", user]
        }
        if let port = sshPort {
            args += ["-p", String(port)]
        }
        args.append(sshHost)
        return args
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func appendAndCheck(_ chunk: Data, marker: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.range(of: marker) != nil { return true }
        data = data.suffix(marker.count)
        return false
    }
}

public enum ReconnectBackoff {
    /// A connection that stays up this long gets its retry counter reset.
    public static let stableAfter: TimeInterval = 60

    /// Exponential backoff capped at 300s, with ±25% jitter and a 1s floor.
    public static func delay(retryCount: Int, jitter: Double = Double.random(in: -0.25...0.25)) -> Double {
        let baseDelay = min(pow(2.0, Double(retryCount)), 300.0)
        return max(1.0, baseDelay + baseDelay * jitter)
    }
}

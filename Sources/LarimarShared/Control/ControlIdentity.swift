import CryptoKit
import Foundation

/// SSH-level identity of a control host. Any change means a different host.
public struct ControlHostIdentity: Hashable, Sendable {
    public let name: String
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: UInt16?

    public init(name: String, sshHost: String, sshUser: String? = nil, sshPort: UInt16? = nil) {
        self.name = name
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
    }

    /// Whether a tunnel config connects through the same SSH identity.
    public func matches(sshHost: String, sshUser: String?, sshPort: UInt16?) -> Bool {
        self.sshHost == sshHost && self.sshUser == sshUser && self.sshPort == sshPort
    }
}

/// Owner of runtime state created through a control socket. The generation
/// changes whenever the host is (re)created, revoking everything the previous
/// incarnation owned.
public struct ControlOwner: Hashable, Sendable {
    public let name: String
    public let generation: UInt64

    public init(name: String, generation: UInt64) {
        self.name = name
        self.generation = generation
    }
}

public enum ControlPaths {
    /// sun_path limit including the terminating NUL (macOS 104, Linux 108).
    public static let maxSocketPathBytes = 104
    public static let remoteSocketName = "control.sock"
    public static let macSocketDirectoryName = "larimar-control"

    /// OpenSSH treats ':' as a separator and expands '\', '$' and '~' in
    /// forwarding specs, so only a conservative character set is accepted:
    /// [A-Za-z0-9._/+-]. '_' is required for macOS per-user temp directories.
    public static func isSafeSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count + 1 <= maxSocketPathBytes else { return false }
        return path.utf8.allSatisfy { b in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
                || "._/+-".utf8.contains(b)
        }
    }

    /// Build and validate the remote socket path from the pre-step output.
    public static func remoteSocketPath(fromPrepOutput output: String) -> String? {
        guard !output.isEmpty, !output.hasSuffix("/") else { return nil }
        let path = output + "/" + remoteSocketName
        return isSafeSocketPath(path) ? path : nil
    }

    /// Socket file name bound to the host identity and generation.
    public static func macSocketFileName(identity: ControlHostIdentity, generation: UInt64) -> String {
        let material = [
            identity.name,
            identity.sshHost,
            identity.sshUser ?? "",
            identity.sshPort.map(String.init) ?? "",
            String(generation),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16)) + ".sock"
    }

    /// POSIX sh script run on the remote host before each control connection
    /// attempt. Prepares a private ~/.larimar and removes a stale socket.
    public static let remotePrepScript = """
    set -eu
    umask 077
    d="$HOME/.larimar"; s="$d/control.sock"
    [ -L "$d" ] && { echo "larimar: $d is a symlink" >&2; exit 3; }
    [ -e "$d" ] || mkdir "$d"
    [ -d "$d" ] && [ -O "$d" ] || { echo "larimar: $d is not a directory owned by the user" >&2; exit 4; }
    chmod 700 "$d"
    if [ -L "$s" ] || { [ -e "$s" ] && [ ! -S "$s" ]; }; then echo "larimar: $s is not a socket" >&2; exit 5; fi
    rm -f "$s"
    printf '%s' "$d"

    """

    /// Pre-step exit codes that indicate a remote problem retries cannot fix.
    public static let permanentPrepExitCodes: Set<Int32> = [3, 4, 5]
}

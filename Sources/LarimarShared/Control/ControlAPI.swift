import Foundation

// MARK: - Routing

public enum ControlRoute: Sendable, Equatable {
    case health
    case listForwards
    case createForward
    case getForward(id: String)
    case deleteForward(id: String)
    case setHint(id: String)
    case clearHint(id: String)

    /// Resolve a method and path into a route, or an API error (404/405).
    public static func resolve(method: String, path: String) -> Result<ControlRoute, ControlAPIError> {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard segments.first == "v1", !segments.contains(where: \.isEmpty) else {
            return .failure(.notFound)
        }

        switch Array(segments.dropFirst()) {
        case ["health"]:
            return method == "GET" ? .success(.health) : .failure(.methodNotAllowed)
        case ["forwards"]:
            switch method {
            case "GET": return .success(.listForwards)
            case "POST": return .success(.createForward)
            default: return .failure(.methodNotAllowed)
            }
        case let parts where parts.count == 2 && parts[0] == "forwards":
            switch method {
            case "GET": return .success(.getForward(id: parts[1]))
            case "DELETE": return .success(.deleteForward(id: parts[1]))
            default: return .failure(.methodNotAllowed)
            }
        case let parts where parts.count == 3 && parts[0] == "forwards" && parts[2] == "hint":
            switch method {
            case "POST": return .success(.setHint(id: parts[1]))
            case "DELETE": return .success(.clearHint(id: parts[1]))
            default: return .failure(.methodNotAllowed)
            }
        default:
            return .failure(.notFound)
        }
    }

    /// Whether the route requires a JSON request body.
    public var requiresJSONBody: Bool {
        switch self {
        case .createForward, .setHint: return true
        default: return false
        }
    }
}

// MARK: - Errors

public struct ControlAPIError: Error, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public static let notFound = ControlAPIError(status: 404, code: "not_found", message: "not found")
    public static let methodNotAllowed = ControlAPIError(status: 405, code: "method_not_allowed", message: "method not allowed")

    public static let hostRevoked = ControlAPIError(status: 404, code: "host_revoked", message: "this control host is no longer allowed")
    public static let denied = ControlAPIError(status: 403, code: "denied", message: "the request was denied")
    public static let recentlyDenied = ControlAPIError(status: 403, code: "recently_denied", message: "the same request was denied recently; clear it from Recently Denied in the Larimar menu to ask again")
    public static let approvalTimeout = ControlAPIError(status: 408, code: "approval_timeout", message: "the request was not approved in time")
    public static let tooManyPending = ControlAPIError(status: 429, code: "too_many_pending", message: "too many pending approval requests")
    public static let rateLimited = ControlAPIError(status: 429, code: "rate_limited", message: "too many approval prompts were shown recently; try again later")
    public static let cancelled = ControlAPIError(status: 503, code: "cancelled", message: "the request was cancelled")
    public static let noLocalPort = ControlAPIError(status: 503, code: "no_local_port", message: "no free local port available")
    public static let shuttingDown = ControlAPIError(status: 503, code: "shutting_down", message: "Larimar is shutting down")
    public static let busy = ControlAPIError(status: 503, code: "busy", message: "too many connections")
    public static let requestTimeout = ControlAPIError(status: 408, code: "timeout", message: "request not received in time")

    public static func badRequest(_ message: String) -> ControlAPIError {
        ControlAPIError(status: 400, code: "invalid_request", message: message)
    }

    public static func localPortInUse(_ port: UInt16) -> ControlAPIError {
        ControlAPIError(status: 409, code: "local_port_in_use", message: "local port \(port) is already in use")
    }

    public static func localPortConflict(id: String, port: UInt16) -> ControlAPIError {
        ControlAPIError(status: 409, code: "local_port_conflict", message: "forward \(id) already exists with local port \(port)")
    }

    public var response: HTTPResponse {
        .error(status, code: code, message: message)
    }
}

// MARK: - Request Bodies

public struct CreateForwardBody: Decodable, Sendable {
    public let app: String
    public let remotePort: Int
    public let forwardHost: String?
    public let localPort: Int?
    public let hint: String?

    private enum CodingKeys: String, CodingKey {
        case app
        case remotePort = "remote_port"
        case forwardHost = "forward_host"
        case localPort = "local_port"
        case hint
    }
}

public struct HintBody: Decodable, Sendable {
    public let hint: String
}

/// A create request that passed validation.
public struct ForwardRequest: Sendable, Equatable {
    public let app: String
    public let remotePort: UInt16
    public let forwardHost: String
    /// Explicit local port; nil means automatic allocation.
    public let localPort: UInt16?
    public let hint: String?

    public init(app: String, remotePort: UInt16, forwardHost: String = "localhost", localPort: UInt16? = nil, hint: String? = nil) {
        self.app = app
        self.remotePort = remotePort
        self.forwardHost = forwardHost
        self.localPort = localPort
        self.hint = hint
    }
}

// MARK: - Validation

public enum ControlValidation {
    public static let maxHintLength = 200

    /// Check that a request carries a JSON content type.
    public static func requireJSON(_ request: HTTPRequest) -> ControlAPIError? {
        let contentType = request.header("Content-Type")?.lowercased() ?? ""
        let mediaType = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard mediaType == "application/json" else {
            return ControlAPIError(status: 415, code: "unsupported_media_type", message: "Content-Type must be application/json")
        }
        return nil
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) -> Result<T, ControlAPIError> {
        do {
            return .success(try JSONDecoder().decode(type, from: body))
        } catch {
            return .failure(.badRequest("invalid JSON body"))
        }
    }

    public static func validateCreate(_ body: CreateForwardBody) -> Result<ForwardRequest, ControlAPIError> {
        guard isValidApp(body.app) else {
            return .failure(.badRequest("app must match [a-z0-9._-]{1,32}"))
        }
        guard let remotePort = port(body.remotePort) else {
            return .failure(.badRequest("remote_port must be between 1 and 65535"))
        }
        var localPort: UInt16?
        if let raw = body.localPort {
            guard let value = port(raw) else {
                return .failure(.badRequest("local_port must be between 1 and 65535"))
            }
            localPort = value
        }
        let forwardHost = body.forwardHost ?? "localhost"
        guard isValidForwardHost(forwardHost) else {
            return .failure(.badRequest("forward_host must match [A-Za-z0-9.-]{1,253}"))
        }
        return sanitizeHint(body.hint ?? "").map { hint in
            ForwardRequest(app: body.app, remotePort: remotePort, forwardHost: forwardHost, localPort: localPort, hint: hint)
        }
    }

    /// Strip control characters and enforce the length limit. Empty hints become nil.
    public static func sanitizeHint(_ raw: String) -> Result<String?, ControlAPIError> {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count <= maxHintLength else {
            return .failure(.badRequest("hint must be at most \(maxHintLength) characters"))
        }
        return .success(cleaned.isEmpty ? nil : cleaned)
    }

    public static func isValidApp(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count)
            && value.utf8.allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    public static func isValidForwardHost(_ value: String) -> Bool {
        (1...253).contains(value.utf8.count)
            && value.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    /// Control host names become TOML table keys and must not contain dots.
    public static func isValidHostName(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func port(_ value: Int) -> UInt16? {
        (1...65535).contains(value) ? UInt16(value) : nil
    }

    private static func isLowerAlnum(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        isLowerAlnum(b) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
    }
}

// MARK: - Response Views

public struct HealthView: Codable, Sendable, Equatable {
    public let version: String
    public let host: String

    public init(version: String, host: String) {
        self.version = version
        self.host = host
    }
}

/// Stable error codes reported to remote hosts. The raw ssh output stays on the
/// Mac (menu, CLI, logs): it can name local files such as ~/.ssh/known_hosts.
public enum ForwardErrorCode: String, Codable, Sendable {
    case hostKeyMismatch = "host_key_mismatch"
    case authFailed = "auth_failed"
    case forwardFailed = "forward_failed"
    case connectFailed = "connect_failed"
    case sshFailed = "ssh_failed"

    private static let patterns: [(ForwardErrorCode, [String])] = [
        // The message keeps only the tail of ssh's output, so the WARNING banner may be gone
        (.hostKeyMismatch, ["host key verification failed", "identification has changed", "host key", "offending key", "known_hosts"]),
        (.authFailed, ["permission denied", "authentication", "too many authentication failures"]),
        (.forwardFailed, ["forwarding failed", "cannot listen", "address already in use", "bind:", "forward"]),
        (.connectFailed, [
            "could not resolve", "connection refused", "timed out", "no route to host",
            "network is unreachable", "connection reset", "connection closed", "broken pipe", "kex_exchange_identification",
        ]),
    ]

    /// Classify an ssh error message; anything unrecognized is `sshFailed`.
    public init(message: String) {
        let text = message.lowercased()
        self = Self.patterns.first { _, needles in needles.contains { text.contains($0) } }?.0 ?? .sshFailed
    }
}

public struct ForwardView: Codable, Sendable, Equatable {
    public let id: String
    public let source: TunnelSource
    public let app: String?
    public let hint: String?
    public let status: TunnelStatus
    public let error: ForwardErrorCode?
    public let remotePort: UInt16
    public let forwardHost: String
    public let localPort: UInt16
    public let localURL: String

    private enum CodingKeys: String, CodingKey {
        case id, source, app, hint, status, error
        case remotePort = "remote_port"
        case forwardHost = "forward_host"
        case localPort = "local_port"
        case localURL = "local_url"
    }

    public init(info: TunnelInfo) {
        self.id = info.id
        self.source = info.source
        self.app = info.app
        self.hint = info.hint
        self.status = info.status
        self.error = info.errorMessage.map(ForwardErrorCode.init(message:))
        self.remotePort = info.remotePort
        self.forwardHost = info.forwardHost
        self.localPort = info.localPort
        self.localURL = info.localURL
    }
}

public struct ForwardListView: Codable, Sendable, Equatable {
    public let forwards: [ForwardView]

    public init(forwards: [ForwardView]) {
        self.forwards = forwards
    }
}

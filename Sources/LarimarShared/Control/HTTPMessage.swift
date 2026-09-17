import Foundation

/// Size limits applied while reading a control request, before any processing.
public struct HTTPLimits: Sendable {
    public let maxRequestLineBytes: Int
    public let maxHeaderBytes: Int
    public let maxHeaderCount: Int
    public let maxBodyBytes: Int

    public init(maxRequestLineBytes: Int = 8 * 1024, maxHeaderBytes: Int = 16 * 1024, maxHeaderCount: Int = 64, maxBodyBytes: Int = 16 * 1024) {
        self.maxRequestLineBytes = maxRequestLineBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.maxHeaderCount = maxHeaderCount
        self.maxBodyBytes = maxBodyBytes
    }

    public static let `default` = HTTPLimits()

    /// Upper bound of bytes worth buffering for a single request.
    public var maxTotalBytes: Int {
        maxRequestLineBytes + maxHeaderBytes + maxBodyBytes + 4
    }
}

public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// Request target without the query string.
    public let path: String
    public let version: String
    public let headers: [(name: String, value: String)]
    public let body: Data

    public init(method: String, path: String, version: String = "HTTP/1.1", headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.path = path
        self.version = version
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive lookup of the first header with the given name.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.version == rhs.version
            && lhs.body == rhs.body
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }
}

public enum HTTPParseResult: Sendable, Equatable {
    case incomplete
    case complete(HTTPRequest)
    case failure(status: Int, message: String)
}

/// Strict, minimal HTTP/1.x request parser for the control socket.
/// One request per connection; no chunked encoding, no pipelining.
public enum HTTPRequestParser {
    private static let crlf = Data("\r\n".utf8)
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data, limits: HTTPLimits = .default) -> HTTPParseResult {
        guard let headerEnd = data.range(of: headerTerminator) else {
            if let lineEnd = data.range(of: crlf) {
                if lineEnd.lowerBound - data.startIndex > limits.maxRequestLineBytes {
                    return .failure(status: 414, message: "request line too long")
                }
                if data.count > limits.maxRequestLineBytes + limits.maxHeaderBytes + 4 {
                    return .failure(status: 431, message: "headers too large")
                }
            } else if data.count > limits.maxRequestLineBytes {
                return .failure(status: 414, message: "request line too long")
            }
            return .incomplete
        }

        let head = data[data.startIndex..<headerEnd.lowerBound]
        guard let headString = String(data: head, encoding: .utf8) else {
            return .failure(status: 400, message: "invalid encoding")
        }
        var lines = headString.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()

        if requestLine.utf8.count > limits.maxRequestLineBytes {
            return .failure(status: 414, message: "request line too long")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
            return .failure(status: 400, message: "malformed request line")
        }
        let method = String(parts[0])
        guard method.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            return .failure(status: 400, message: "malformed method")
        }
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(status: 505, message: "unsupported HTTP version")
        }
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        let headerBytes = headString.utf8.count - requestLine.utf8.count
        if headerBytes > limits.maxHeaderBytes {
            return .failure(status: 431, message: "headers too large")
        }
        if lines.count > limits.maxHeaderCount {
            return .failure(status: 431, message: "too many headers")
        }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, message: "malformed header")
            }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else {
                return .failure(status: 400, message: "malformed header name")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append((name: name, value: value))
        }

        let request = HTTPRequest(method: method, path: path, version: version, headers: headers)
        if request.header("Transfer-Encoding") != nil {
            return .failure(status: 400, message: "transfer-encoding is not supported")
        }

        let lengthHeaders = headers.filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        var contentLength = 0
        if lengthHeaders.count > 1 {
            return .failure(status: 400, message: "duplicate content-length")
        }
        if let raw = lengthHeaders.first?.value {
            guard !raw.isEmpty, raw.utf8.count <= 10, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw) else {
                return .failure(status: 400, message: "invalid content-length")
            }
            contentLength = value
        }
        if contentLength > limits.maxBodyBytes {
            return .failure(status: 413, message: "body too large")
        }

        let bodyStart = headerEnd.upperBound
        let available = data.endIndex - bodyStart
        if available < contentLength {
            return .incomplete
        }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return .complete(HTTPRequest(method: method, path: path, version: version, headers: headers, body: body))
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let scalar = c.unicodeScalars.first else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "!#$%&'*+-.^_`|~".contains(c)
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    public static func error(_ status: Int, code: String, message: String) -> HTTPResponse {
        json(status, ControlErrorView(error: code, message: message))
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count + 1)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        // Trailing newline keeps curl output readable in a terminal
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Unknown"
        }
    }
}

public struct ControlErrorView: Codable, Sendable, Equatable {
    public let error: String
    public let message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}

import Foundation

public struct LarimarConfig: Sendable {
    public let managed: Bool
    public let defaults: DefaultsConfig
    public let tunnels: [TunnelConfig]

    public init(managed: Bool = false, defaults: DefaultsConfig, tunnels: [TunnelConfig]) {
        self.managed = managed
        self.defaults = defaults
        self.tunnels = tunnels
    }
}

public struct DefaultsConfig: Sendable {
    public let bindAddress: String
    public let autoConnect: Bool
    public let autoReconnect: Bool
    public let sshAuthSock: String?
    public let sshUser: String?
    public let sshPort: UInt16?

    public init(
        bindAddress: String = "127.0.0.1",
        autoConnect: Bool = false,
        autoReconnect: Bool = true,
        sshAuthSock: String? = nil,
        sshUser: String? = nil,
        sshPort: UInt16? = nil
    ) {
        self.bindAddress = bindAddress
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.sshAuthSock = sshAuthSock
        self.sshUser = sshUser
        self.sshPort = sshPort
    }
}

// MARK: - Minimal TOML Parser

/// A lightweight TOML parser supporting tables, dotted table keys, strings, integers, and booleans.
/// Sufficient for parsing Larimar's tunnels.toml configuration.
enum TOMLParser {
    enum Value {
        case string(String)
        case int(Int)
        case bool(Bool)
        case table([String: Value])
    }

    static func parse(_ input: String) throws -> [String: Value] {
        var root: [String: Value] = [:]
        var currentPath: [String] = []

        for rawLine in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Table header: [section] or [section.subsection]
            if line.hasPrefix("[") && !line.hasPrefix("[[") {
                guard let closing = line.firstIndex(of: "]") else { continue }
                let key = line[line.index(after: line.startIndex)..<closing]
                    .trimmingCharacters(in: .whitespaces)
                currentPath = key.split(separator: ".").map(String.init)
                // Ensure the nested table exists
                ensurePath(&root, path: currentPath)
                continue
            }

            // Key = Value
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            // Strip inline comments (not inside strings)
            let value = parseValue(rawValue)
            setNestedValue(&root, path: currentPath + [key], value: value)
        }

        return root
    }

    private static func parseValue(_ raw: String) -> Value {
        // Quoted string
        if raw.hasPrefix("\"") {
            // Find closing quote, handling the value possibly having an inline comment after
            if let end = raw.dropFirst().firstIndex(of: "\"") {
                let str = String(raw[raw.index(after: raw.startIndex)..<end])
                return .string(str)
            }
            return .string(String(raw.dropFirst().dropLast()))
        }

        // Strip inline comment for non-string values
        let stripped: String
        if let commentIdx = raw.firstIndex(of: "#") {
            stripped = raw[raw.startIndex..<commentIdx].trimmingCharacters(in: .whitespaces)
        } else {
            stripped = raw
        }

        // Boolean
        if stripped == "true" { return .bool(true) }
        if stripped == "false" { return .bool(false) }

        // Integer
        if let intVal = Int(stripped) { return .int(intVal) }

        // Fallback to string
        return .string(stripped)
    }

    private static func ensurePath(_ root: inout [String: Value], path: [String]) {
        var current = root
        var segments: [String] = []
        for segment in path {
            segments.append(segment)
            if case .table(let existing) = current[segment] {
                current = existing
            } else {
                // Build remaining path
                setNestedValue(&root, path: segments, value: .table(current[segment].flatMap {
                    if case .table(let t) = $0 { return t } else { return nil }
                } ?? [:]))
                current = [:]
            }
        }
    }

    private static func setNestedValue(_ root: inout [String: Value], path: [String], value: Value) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            root[path[0]] = value
            return
        }

        var sub: [String: Value]
        if case .table(let existing) = root[path[0]] {
            sub = existing
        } else {
            sub = [:]
        }
        setNestedValue(&sub, path: Array(path.dropFirst()), value: value)
        root[path[0]] = .table(sub)
    }
}

// MARK: - Config Load Result

public struct ConfigLoadResult: Sendable {
    public let config: LarimarConfig
    public let warnings: [String]

    public init(config: LarimarConfig, warnings: [String] = []) {
        self.config = config
        self.warnings = warnings
    }
}

// MARK: - Config Loader

public enum ConfigLoader {
    public static func load(from path: String? = nil) throws -> ConfigLoadResult {
        let configPath = path ?? LarimarConstants.defaultConfigPath
        let expandedPath = NSString(string: configPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content)
    }

    public static func parse(_ toml: String) throws -> ConfigLoadResult {
        let table = try TOMLParser.parse(toml)
        let managed: Bool
        if case .bool(let v) = table["managed"] { managed = v } else { managed = false }
        let defaults = parseDefaults(table["defaults"])
        var tunnels: [TunnelConfig] = []
        var warnings: [String] = []

        if case .table(let tunnelsTable) = table["tunnels"] {
            // Sort keys for stable warning order
            for id in tunnelsTable.keys.sorted() {
                guard case .table(let tunnelTable) = tunnelsTable[id] else { continue }

                // Detect renamed key
                if tunnelTable.string("remote_host") != nil {
                    warnings.append("tunnel '\(id)': 'remote_host' has been renamed to 'forward_host'")
                    continue
                }

                // Validate mode: must be a recognized string if present
                if let modeValue = tunnelTable["mode"] {
                    guard case .string(let modeStr) = modeValue, TunnelMode(rawValue: modeStr) != nil else {
                        let desc: String
                        if case .string(let s) = modeValue { desc = "'\(s)'" } else { desc = "non-string value" }
                        warnings.append("tunnel '\(id)': invalid mode \(desc)")
                        continue
                    }
                }

                let tunnel = parseTunnel(id: id, table: tunnelTable, defaults: defaults)

                // Validate required fields
                if tunnel.sshHost.isEmpty {
                    warnings.append("tunnel '\(id)': ssh_host is missing")
                    continue
                }
                if tunnel.localPort == 0 {
                    warnings.append("tunnel '\(id)': local_port is missing or zero")
                    continue
                }
                if tunnel.mode != .dynamic && tunnel.remotePort == 0 {
                    warnings.append("tunnel '\(id)': remote_port is missing or zero")
                    continue
                }

                tunnels.append(tunnel)
            }
        }

        tunnels.sort { $0.id < $1.id }
        return ConfigLoadResult(config: LarimarConfig(managed: managed, defaults: defaults, tunnels: tunnels), warnings: warnings)
    }

    private static func parseDefaults(_ value: TOMLParser.Value?) -> DefaultsConfig {
        guard case .table(let table) = value else {
            return DefaultsConfig()
        }
        return DefaultsConfig(
            bindAddress: table.string("bind_address") ?? "127.0.0.1",
            autoConnect: table.bool("auto_connect") ?? false,
            autoReconnect: table.bool("auto_reconnect") ?? true,
            sshAuthSock: table.string("ssh_auth_sock"),
            sshUser: table.string("ssh_user"),
            sshPort: table.uint16("ssh_port")
        )
    }

    private static func parseTunnel(id: String, table: [String: TOMLParser.Value], defaults: DefaultsConfig) -> TunnelConfig {
        let mode: TunnelMode
        if let modeStr = table.string("mode") {
            mode = TunnelMode(rawValue: modeStr) ?? .local
        } else {
            mode = .local
        }

        return TunnelConfig(
            id: id,
            mode: mode,
            localPort: table.uint16("local_port") ?? 0,
            remotePort: table.uint16("remote_port") ?? 0,
            forwardHost: table.string("forward_host") ?? "localhost",
            sshHost: table.string("ssh_host") ?? "",
            sshUser: table.string("ssh_user") ?? defaults.sshUser,
            sshPort: table.uint16("ssh_port") ?? defaults.sshPort,
            bindAddress: table.string("bind_address") ?? defaults.bindAddress,
            autoConnect: table.bool("auto_connect") ?? defaults.autoConnect,
            autoReconnect: table.bool("auto_reconnect") ?? defaults.autoReconnect
        )
    }
}

// MARK: - Value Accessors

private extension Dictionary where Key == String, Value == TOMLParser.Value {
    func string(_ key: String) -> String? {
        if case .string(let v) = self[key] { return v }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let v) = self[key] { return v }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let v) = self[key] { return v }
        return nil
    }

    func uint16(_ key: String) -> UInt16? {
        guard let i = int(key) else { return nil }
        return UInt16(exactly: i)
    }
}

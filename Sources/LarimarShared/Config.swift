import Foundation

public struct LarimarConfig: Sendable {
    public let managed: Bool
    public let defaults: DefaultsConfig
    public let tunnels: [TunnelConfig]
    public let control: ControlConfig

    public init(managed: Bool = false, defaults: DefaultsConfig, tunnels: [TunnelConfig], control: ControlConfig = ControlConfig()) {
        self.managed = managed
        self.defaults = defaults
        self.tunnels = tunnels
        self.control = control
    }
}

/// Settings for the control socket that lets allowed remote hosts request forwards.
public struct ControlConfig: Sendable, Equatable {
    public static let defaultApprovalTimeout = 120

    public let enabled: Bool
    public let approvalTimeout: Int
    public let hosts: [ControlHost]

    public init(enabled: Bool = false, approvalTimeout: Int = ControlConfig.defaultApprovalTimeout, hosts: [ControlHost] = []) {
        self.enabled = enabled
        self.approvalTimeout = approvalTimeout
        self.hosts = hosts
    }
}

/// A remote host allowed to talk to the control socket.
public struct ControlHost: Sendable, Equatable {
    public let name: String
    public let sshHost: String
    public let sshUser: String?
    public let sshPort: UInt16?
    public let autoConnect: Bool

    public init(name: String, sshHost: String, sshUser: String? = nil, sshPort: UInt16? = nil, autoConnect: Bool = false) {
        self.name = name
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.autoConnect = autoConnect
    }

    public var identity: ControlHostIdentity {
        ControlHostIdentity(name: name, sshHost: sshHost, sshUser: sshUser, sshPort: sshPort)
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

    /// ':' is reserved for runtime-generated ids (e.g. "dyn:...").
    public static func isReservedTunnelId(_ id: String) -> Bool {
        id.contains(":")
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

                if isReservedTunnelId(id) {
                    warnings.append("tunnel '\(id)': ':' is not allowed in tunnel ids")
                    continue
                }

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

                if let app = tunnelTable.string("app"), !ControlValidation.isValidApp(app) {
                    warnings.append("tunnel '\(id)': invalid app '\(app)' (allowed: a-z 0-9 . _ -, max 32)")
                    continue
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
        let control = parseControl(table["control"], defaults: defaults, warnings: &warnings)
        return ConfigLoadResult(
            config: LarimarConfig(managed: managed, defaults: defaults, tunnels: tunnels, control: control),
            warnings: warnings
        )
    }

    private static func parseControl(_ value: TOMLParser.Value?, defaults: DefaultsConfig, warnings: inout [String]) -> ControlConfig {
        guard case .table(let table) = value else {
            return ControlConfig()
        }

        var approvalTimeout = ControlConfig.defaultApprovalTimeout
        if let timeout = table.int("approval_timeout") {
            if (10...3600).contains(timeout) {
                approvalTimeout = timeout
            } else {
                warnings.append("control: approval_timeout must be between 10 and 3600, using \(approvalTimeout)")
            }
        }

        var hosts: [ControlHost] = []
        if case .table(let hostsTable) = table["hosts"] {
            for name in hostsTable.keys.sorted() {
                guard case .table(let hostTable) = hostsTable[name] else { continue }
                guard ControlValidation.isValidHostName(name) else {
                    warnings.append("control host '\(name)': invalid name (allowed: A-Z a-z 0-9 _ -)")
                    continue
                }
                guard let sshHost = hostTable.string("ssh_host"), !sshHost.isEmpty else {
                    warnings.append("control host '\(name)': ssh_host is missing")
                    continue
                }
                hosts.append(ControlHost(
                    name: name,
                    sshHost: sshHost,
                    sshUser: hostTable.string("ssh_user") ?? defaults.sshUser,
                    sshPort: hostTable.uint16("ssh_port") ?? defaults.sshPort,
                    autoConnect: hostTable.bool("auto_connect") ?? defaults.autoConnect
                ))
            }
        }

        return ControlConfig(
            enabled: table.bool("enabled") ?? false,
            approvalTimeout: approvalTimeout,
            hosts: hosts
        )
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
            autoReconnect: table.bool("auto_reconnect") ?? defaults.autoReconnect,
            app: table.string("app")
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

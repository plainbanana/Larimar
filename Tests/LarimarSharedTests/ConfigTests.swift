import Foundation
import LarimarShared

// Minimal test harness for environments without XCTest/Xcode
var failures = 0
var passed = 0

func expect<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failures += 1
        print("  FAIL [\(file):\(line)] expected \(b), got \(a) \(msg)")
    }
}

func expectNil<T>(_ value: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    if value == nil {
        passed += 1
    } else {
        failures += 1
        print("  FAIL [\(file):\(line)] expected nil, got \(value!) \(msg)")
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  PASS \(name)")
    } catch {
        failures += 1
        print("  FAIL \(name): \(error)")
    }
}

// MARK: - Tests

print("Running Larimar tests...\n")

test("parseMinimalConfig") {
    let toml = """
    [tunnels.web]
    local_port = 8080
    remote_port = 8080
    ssh_host = "myserver"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 1)

    let tunnel = result.config.tunnels[0]
    expect(tunnel.id, "web")
    expect(tunnel.mode, .local)
    expect(tunnel.localPort, 8080)
    expect(tunnel.remotePort, 8080)
    expect(tunnel.forwardHost, "localhost")
    expect(tunnel.sshHost, "myserver")
    expect(tunnel.bindAddress, "127.0.0.1")
    expect(tunnel.autoConnect, false)
    expect(tunnel.autoReconnect, true)
    expectNil(tunnel.sshUser)
    expectNil(tunnel.sshPort)
}

test("parseFullConfig") {
    let toml = """
    [defaults]
    bind_address = "0.0.0.0"
    auto_connect = true
    auto_reconnect = false
    ssh_auth_sock = "/tmp/agent.sock"
    ssh_user = "admin"
    ssh_port = 2222

    [tunnels.db]
    local_port = 5432
    remote_port = 5432
    forward_host = "db.internal"
    ssh_host = "bastion"
    auto_connect = false
    auto_reconnect = true
    bind_address = "127.0.0.1"
    ssh_user = "dbadmin"
    ssh_port = 22
    """

    let result = try ConfigLoader.parse(toml)

    expect(result.config.defaults.bindAddress, "0.0.0.0")
    expect(result.config.defaults.autoConnect, true)
    expect(result.config.defaults.autoReconnect, false)
    expect(result.config.defaults.sshAuthSock, "/tmp/agent.sock")
    expect(result.config.defaults.sshUser, "admin")
    expect(result.config.defaults.sshPort, 2222)

    let tunnel = result.config.tunnels[0]
    expect(tunnel.id, "db")
    expect(tunnel.forwardHost, "db.internal")
    expect(tunnel.autoConnect, false)
    expect(tunnel.autoReconnect, true)
    expect(tunnel.bindAddress, "127.0.0.1")
    expect(tunnel.sshUser, "dbadmin")
    expect(tunnel.sshPort, 22)
}

test("parseTunnelsSortedById") {
    let toml = """
    [tunnels.charlie]
    local_port = 3000
    remote_port = 3000
    ssh_host = "server"

    [tunnels.alpha]
    local_port = 1000
    remote_port = 1000
    ssh_host = "server"

    [tunnels.bravo]
    local_port = 2000
    remote_port = 2000
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 3)
    expect(result.config.tunnels.map(\.id), ["alpha", "bravo", "charlie"])
}

test("parseEmptyConfig") {
    let result = try ConfigLoader.parse("")
    expect(result.config.tunnels.count, 0)
    expect(result.config.defaults.bindAddress, "127.0.0.1")
    expect(result.config.defaults.autoConnect, false)
    expect(result.config.defaults.autoReconnect, true)
}

test("defaultsInheritance") {
    let toml = """
    [defaults]
    ssh_user = "shared-user"
    ssh_port = 2222
    bind_address = "10.0.0.1"

    [tunnels.svc]
    local_port = 9000
    remote_port = 9000
    ssh_host = "gateway"
    """

    let result = try ConfigLoader.parse(toml)
    let tunnel = result.config.tunnels[0]
    expect(tunnel.sshUser, "shared-user")
    expect(tunnel.sshPort, 2222)
    expect(tunnel.bindAddress, "10.0.0.1")
}

test("ipcMessageRoundTrip") {
    let commands: [IPCCommand] = [
        .status,
        .connect(tunnelId: "web"),
        .disconnect(tunnelId: "db"),
        .connectAll,
        .disconnectAll,
        .list,
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let decoder = JSONDecoder()

    for command in commands {
        let request = IPCRequest(id: "test-123", command: command)
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(IPCRequest.self, from: data)
        expect(decoded.id, "test-123")

        let reEncoded = try encoder.encode(decoded)
        let original = try encoder.encode(request)
        expect(reEncoded, original)
    }
}

test("ipcResponseEncoding") {
    let tunnelInfo = TunnelInfo(
        id: "web",
        status: .connected,
        localPort: 8080,
        remotePort: 8080,
        sshHost: "server"
    )
    let response = IPCResponse.ok(id: "req-1", data: IPCResponseData(tunnels: [tunnelInfo]))

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)

    expect(decoded.success, true)
    expect(decoded.data?.tunnels.count, 1)
    expect(decoded.data?.tunnels[0].id, "web")
    expect(decoded.data?.tunnels[0].status, .connected)
    expect(decoded.data?.tunnels[0].mode, .local)
}

test("inlineComments") {
    let toml = """
    [tunnels.svc]
    local_port = 9022          # some comment
    remote_port = 9022
    ssh_host = "bastion"       # host alias
    auto_connect = true        # auto
    """

    let result = try ConfigLoader.parse(toml)
    let tunnel = result.config.tunnels[0]
    expect(tunnel.localPort, 9022)
    expect(tunnel.sshHost, "bastion")
    expect(tunnel.autoConnect, true)
}

test("invalidTunnelSkippedGoodSurvives") {
    let toml = """
    [tunnels.good]
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"

    [tunnels.no-host]
    local_port = 9090
    remote_port = 9090

    [tunnels.no-port]
    remote_port = 3000
    ssh_host = "server"

    [tunnels.also-good]
    local_port = 5432
    remote_port = 5432
    ssh_host = "db-server"
    """

    let result = try ConfigLoader.parse(toml)

    // Good tunnels survive
    expect(result.config.tunnels.count, 2)
    expect(result.config.tunnels[0].id, "also-good")
    expect(result.config.tunnels[1].id, "good")

    // Bad tunnels produce sorted warnings
    expect(result.warnings.count, 2)
    expect(result.warnings[0], "tunnel 'no-host': ssh_host is missing")
    expect(result.warnings[1], "tunnel 'no-port': local_port is missing or zero")
}

test("sshParametersDiffer") {
    let base = TunnelConfig(
        id: "test", localPort: 8080, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        bindAddress: "127.0.0.1"
    )

    // Same config — no diff
    let same = base
    expect(base.sshParametersDiffer(from: same), false)

    // Different localPort
    let diffPort = TunnelConfig(
        id: "test", localPort: 9090, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        bindAddress: "127.0.0.1"
    )
    expect(base.sshParametersDiffer(from: diffPort), true)

    // Different sshHost
    let diffHost = TunnelConfig(
        id: "test", localPort: 8080, remotePort: 8080,
        forwardHost: "localhost", sshHost: "other-server",
        bindAddress: "127.0.0.1"
    )
    expect(base.sshParametersDiffer(from: diffHost), true)

    // Different bindAddress
    let diffBind = TunnelConfig(
        id: "test", localPort: 8080, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        bindAddress: "0.0.0.0"
    )
    expect(base.sshParametersDiffer(from: diffBind), true)

    // Different sshUser
    let diffUser = TunnelConfig(
        id: "test", localPort: 8080, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        sshUser: "admin", bindAddress: "127.0.0.1"
    )
    expect(base.sshParametersDiffer(from: diffUser), true)

    // Different autoConnect only — no diff (not an SSH parameter)
    let diffAuto = TunnelConfig(
        id: "test", localPort: 8080, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        bindAddress: "127.0.0.1", autoConnect: true
    )
    expect(base.sshParametersDiffer(from: diffAuto), false)
}

// MARK: - Mode Tests

test("parseTunnelModeLocal") {
    let toml = """
    [tunnels.web]
    mode = "local"
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 1)
    expect(result.config.tunnels[0].mode, .local)
}

test("parseTunnelModeRemote") {
    let toml = """
    [tunnels.expose]
    mode = "remote"
    local_port = 3000
    remote_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 1)
    expect(result.config.tunnels[0].mode, .remote)
}

test("parseTunnelModeDynamic") {
    let toml = """
    [tunnels.socks]
    mode = "dynamic"
    local_port = 1080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 1)
    expect(result.config.tunnels[0].mode, .dynamic)
    expect(result.config.tunnels[0].remotePort, 0)
    expect(result.warnings.count, 0)
}

test("parseTunnelModeDefaultsToLocal") {
    let toml = """
    [tunnels.web]
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels[0].mode, .local)
}

test("dynamicModeNoRemotePortRequired") {
    let toml = """
    [tunnels.socks]
    mode = "dynamic"
    local_port = 1080
    ssh_host = "server"

    [tunnels.also-socks]
    mode = "dynamic"
    local_port = 1081
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 2)
    expect(result.warnings.count, 0)
}

test("localModeRequiresRemotePort") {
    let toml = """
    [tunnels.broken]
    mode = "local"
    local_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 0)
    expect(result.warnings.count, 1)
    expect(result.warnings[0], "tunnel 'broken': remote_port is missing or zero")
}

test("remoteModeRequiresRemotePort") {
    let toml = """
    [tunnels.broken]
    mode = "remote"
    local_port = 3000
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 0)
    expect(result.warnings.count, 1)
    expect(result.warnings[0], "tunnel 'broken': remote_port is missing or zero")
}

test("unknownModeSkipsTunnel") {
    let toml = """
    [tunnels.web]
    mode = "bogus"
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 0)
    expect(result.warnings.count, 1)
    expect(result.warnings[0], "tunnel 'web': invalid mode 'bogus'")
}

test("nonStringModeSkipsTunnel") {
    let toml = """
    [tunnels.bool-mode]
    mode = true
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"

    [tunnels.int-mode]
    mode = 1
    local_port = 9090
    remote_port = 9090
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 0)
    expect(result.warnings.count, 2)
    expect(result.warnings[0], "tunnel 'bool-mode': invalid mode non-string value")
    expect(result.warnings[1], "tunnel 'int-mode': invalid mode non-string value")
}

test("remoteHostKeySkipsTunnel") {
    let toml = """
    [tunnels.old-style]
    local_port = 8080
    remote_port = 8080
    remote_host = "db.internal"
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.count, 0)
    expect(result.warnings.count, 1)
    expect(result.warnings[0], "tunnel 'old-style': 'remote_host' has been renamed to 'forward_host'")
}

test("forwardHostDefaultsToLocalhost") {
    let toml = """
    [tunnels.web]
    local_port = 8080
    remote_port = 8080
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels[0].forwardHost, "localhost")
}

test("forwardHostParsed") {
    let toml = """
    [tunnels.web]
    local_port = 8080
    remote_port = 8080
    forward_host = "db.internal"
    ssh_host = "server"
    """

    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels[0].forwardHost, "db.internal")
}

// MARK: - SSH Forward Arguments Tests

test("sshForwardArgumentsLocal") {
    let config = TunnelConfig(
        id: "test", mode: .local,
        localPort: 8080, remotePort: 80,
        forwardHost: "db.internal", sshHost: "server",
        bindAddress: "127.0.0.1"
    )
    expect(config.sshForwardArguments(), ["-L", "127.0.0.1:8080:db.internal:80"])
}

test("sshForwardArgumentsRemote") {
    let config = TunnelConfig(
        id: "test", mode: .remote,
        localPort: 3000, remotePort: 8080,
        forwardHost: "localhost", sshHost: "server",
        bindAddress: "0.0.0.0"
    )
    expect(config.sshForwardArguments(), ["-R", "0.0.0.0:8080:localhost:3000"])
}

test("sshForwardArgumentsDynamic") {
    let config = TunnelConfig(
        id: "test", mode: .dynamic,
        localPort: 1080, remotePort: 0,
        sshHost: "server", bindAddress: "127.0.0.1"
    )
    expect(config.sshForwardArguments(), ["-D", "127.0.0.1:1080"])
}

// MARK: - IPC Backward Compatibility Tests

test("ipcDecodeWithoutModeDefaultsToLocal") {
    // Simulate JSON from an older daemon that doesn't include "mode"
    let json = """
    {"id":"web","status":"connected","localPort":8080,"remotePort":8080,"sshHost":"server"}
    """
    let decoded = try JSONDecoder().decode(TunnelInfo.self, from: Data(json.utf8))
    expect(decoded.mode, .local)
    expect(decoded.id, "web")
    expect(decoded.status, .connected)
}

test("ipcDecodeWithMode") {
    let json = """
    {"id":"socks","status":"connected","mode":"dynamic","localPort":1080,"remotePort":0,"sshHost":"server"}
    """
    let decoded = try JSONDecoder().decode(TunnelInfo.self, from: Data(json.utf8))
    expect(decoded.mode, .dynamic)
}

test("ipcTunnelInfoRoundTrip") {
    let tunnelInfo = TunnelInfo(
        id: "socks",
        status: .connected,
        mode: .dynamic,
        localPort: 1080,
        remotePort: 0,
        sshHost: "server"
    )
    let data = try JSONEncoder().encode(tunnelInfo)
    let decoded = try JSONDecoder().decode(TunnelInfo.self, from: data)
    expect(decoded.mode, .dynamic)
    expect(decoded.localPort, 1080)
}

// MARK: - sshParametersDiffer with Mode

test("sshParametersDifferOnModeChange") {
    let local = TunnelConfig(
        id: "test", mode: .local, localPort: 8080, remotePort: 8080,
        sshHost: "server"
    )
    let remote = TunnelConfig(
        id: "test", mode: .remote, localPort: 8080, remotePort: 8080,
        sshHost: "server"
    )
    expect(local.sshParametersDiffer(from: remote), true)
}

test("sshParametersDifferDynamicIgnoresUnusedFields") {
    let a = TunnelConfig(
        id: "test", mode: .dynamic, localPort: 1080, remotePort: 0,
        forwardHost: "localhost", sshHost: "server"
    )
    // Different remotePort and forwardHost should NOT trigger differ for dynamic
    let b = TunnelConfig(
        id: "test", mode: .dynamic, localPort: 1080, remotePort: 9999,
        forwardHost: "other.host", sshHost: "server"
    )
    expect(a.sshParametersDiffer(from: b), false)

    // But different localPort should still trigger
    let c = TunnelConfig(
        id: "test", mode: .dynamic, localPort: 2080, remotePort: 0,
        sshHost: "server"
    )
    expect(a.sshParametersDiffer(from: c), true)
}

test("sshParametersDifferSameModeNoDiff") {
    let a = TunnelConfig(
        id: "test", mode: .dynamic, localPort: 1080, remotePort: 0,
        sshHost: "server"
    )
    let b = TunnelConfig(
        id: "test", mode: .dynamic, localPort: 1080, remotePort: 0,
        sshHost: "server"
    )
    expect(a.sshParametersDiffer(from: b), false)
}

// MARK: - Control: Config

test("parseControlConfig") {
    let toml = """
    [defaults]
    ssh_user = "admin"
    auto_connect = true

    [control]
    enabled = true
    approval_timeout = 60

    [control.hosts.devbox]
    ssh_host = "devbox.example.com"

    [control.hosts.other]
    ssh_host = "other"
    ssh_port = 2222
    auto_connect = false
    """
    let result = try ConfigLoader.parse(toml)
    let control = result.config.control
    expect(control.enabled, true)
    expect(control.approvalTimeout, 60)
    expect(control.hosts.map(\.name), ["devbox", "other"])
    expect(control.hosts[0].sshHost, "devbox.example.com")
    expect(control.hosts[0].sshUser, "admin")
    expect(control.hosts[0].autoConnect, true)
    expect(control.hosts[1].sshPort, 2222)
    expect(control.hosts[1].autoConnect, false)
    expect(result.warnings.count, 0)
}

test("controlDisabledByDefault") {
    let result = try ConfigLoader.parse("")
    expect(result.config.control.enabled, false)
    expect(result.config.control.hosts.count, 0)
    expect(result.config.control.approvalTimeout, 120)
}

test("controlInvalidEntriesSkipped") {
    let toml = """
    [control]
    enabled = true
    approval_timeout = 1

    [control.hosts.missing]
    auto_connect = true

    [control.hosts.bad+name]
    ssh_host = "x"
    """
    let result = try ConfigLoader.parse(toml)
    expect(result.config.control.hosts.count, 0)
    expect(result.config.control.approvalTimeout, 120)
    expect(result.warnings.count, 3)
}

test("tunnelAppParsedAndReservedIdSkipped") {
    let toml = """
    [tunnels.someapp-1]
    app = "someapp"
    local_port = 4970
    remote_port = 4970
    ssh_host = "devbox"

    [tunnels.bad-app]
    app = "Bad App"
    local_port = 1
    remote_port = 1
    ssh_host = "devbox"
    """
    let result = try ConfigLoader.parse(toml)
    expect(result.config.tunnels.map(\.id), ["someapp-1"])
    expect(result.config.tunnels[0].app, "someapp")
    expect(result.warnings.count, 1)

    expect(ConfigLoader.isReservedTunnelId("dyn:1234"), true)
    expect(ConfigLoader.isReservedTunnelId("someapp-1"), false)
}

test("appDoesNotTriggerReconnect") {
    let a = TunnelConfig(id: "t", localPort: 1, remotePort: 1, sshHost: "h", app: "someapp")
    let b = TunnelConfig(id: "t", localPort: 1, remotePort: 1, sshHost: "h", app: "otherapp")
    expect(a.sshParametersDiffer(from: b), false)
}

// MARK: - Control: HTTP parser

let CRLF = "\r\n"

func parseHTTP(_ lines: [String], body: String = "", limits: HTTPLimits = .default) -> HTTPParseResult {
    HTTPRequestParser.parse(Data((lines.joined(separator: CRLF) + CRLF + CRLF + body).utf8), limits: limits)
}

func failureStatus(_ result: HTTPParseResult) -> Int {
    if case .failure(let status, _) = result { return status }
    return 0
}

test("httpParseSimpleGet") {
    guard case .complete(let req) = parseHTTP(["GET /v1/health?x=1 HTTP/1.1", "Host: larimar"]) else {
        throw TestError("expected complete")
    }
    expect(req.method, "GET")
    expect(req.path, "/v1/health")
    expect(req.header("host"), "larimar")
}

test("httpParseBodyAndIncomplete") {
    let head = ["POST /v1/forwards HTTP/1.1", "Content-Type: application/json", "Content-Length: 5"]
    expect(parseHTTP(head, body: "ab"), .incomplete)
    let partial = HTTPRequestParser.parse(Data(("GET /v1/health HTTP/1.1" + CRLF + "Host: x" + CRLF).utf8))
    expect(partial, .incomplete)
    guard case .complete(let req) = parseHTTP(head, body: "hello") else { throw TestError("expected complete") }
    expect(String(data: req.body, encoding: .utf8), "hello")
}

test("httpParseRejectsFramingProblems") {
    expect(failureStatus(parseHTTP(["POST /v1/forwards HTTP/1.1", "Transfer-Encoding: chunked"])), 400)
    expect(failureStatus(parseHTTP(["POST /v1/forwards HTTP/1.1", "Content-Length: 1", "Content-Length: 1"], body: "a")), 400)
    expect(failureStatus(parseHTTP(["POST /v1/forwards HTTP/1.1", "Content-Length: -1"])), 400)
    expect(failureStatus(parseHTTP(["POST /v1/forwards HTTP/1.1", "Content-Length: 1x"])), 400)
    expect(failureStatus(parseHTTP(["GET /v1/health HTTP/2.0"])), 505)
    expect(failureStatus(parseHTTP(["GET v1 HTTP/1.1"])), 400)
    expect(failureStatus(parseHTTP(["GET /v1/health HTTP/1.1", "bad header"])), 400)
}

test("httpParseLimits") {
    let limits = HTTPLimits(maxRequestLineBytes: 32, maxHeaderBytes: 64, maxHeaderCount: 2, maxBodyBytes: 4)
    let longLine = HTTPRequestParser.parse(Data(("GET /" + String(repeating: "a", count: 40)).utf8), limits: limits)
    expect(failureStatus(longLine), 414)
    expect(failureStatus(parseHTTP(["GET / HTTP/1.1", "A: 1", "B: 2", "C: 3"], limits: limits)), 431)
    expect(failureStatus(parseHTTP(["GET / HTTP/1.1", "A: " + String(repeating: "x", count: 80)], limits: limits)), 431)
    let unterminated = HTTPRequestParser.parse(Data(("GET / HTTP/1.1" + CRLF + "A: " + String(repeating: "x", count: 120)).utf8), limits: limits)
    expect(failureStatus(unterminated), 431)
    expect(failureStatus(parseHTTP(["POST / HTTP/1.1", "Content-Length: 5"], limits: limits)), 413)
}

test("httpResponseSerialization") {
    let data = HTTPResponse.error(404, code: "not_found", message: "nope").serialized()
    let text = String(data: data, encoding: .utf8) ?? ""
    expect(text.hasPrefix("HTTP/1.1 404 Not Found" + CRLF), true)
    expect(text.contains("Connection: close" + CRLF), true)
    expect(text.hasSuffix(#"{"error":"not_found","message":"nope"}"# + "\n"), true)
}

// MARK: - Control: API

test("controlRoutes") {
    expect(ControlRoute.resolve(method: "GET", path: "/v1/health"), .success(.health))
    expect(ControlRoute.resolve(method: "GET", path: "/v1/forwards"), .success(.listForwards))
    expect(ControlRoute.resolve(method: "POST", path: "/v1/forwards"), .success(.createForward))
    expect(ControlRoute.resolve(method: "GET", path: "/v1/forwards/dyn:1"), .success(.getForward(id: "dyn:1")))
    expect(ControlRoute.resolve(method: "DELETE", path: "/v1/forwards/dyn:1"), .success(.deleteForward(id: "dyn:1")))
    expect(ControlRoute.resolve(method: "POST", path: "/v1/forwards/dyn:1/hint"), .success(.setHint(id: "dyn:1")))
    expect(ControlRoute.resolve(method: "DELETE", path: "/v1/forwards/dyn:1/hint"), .success(.clearHint(id: "dyn:1")))
    expect(ControlRoute.resolve(method: "PATCH", path: "/v1/forwards/dyn:1"), .failure(.methodNotAllowed))
    expect(ControlRoute.resolve(method: "GET", path: "/v1/forwards//hint"), .failure(.notFound))
    expect(ControlRoute.resolve(method: "GET", path: "/v2/health"), .failure(.notFound))
    expect(ControlRoute.resolve(method: "GET", path: "/v1/"), .failure(.notFound))
}

test("controlRequireJSON") {
    expectNil(ControlValidation.requireJSON(HTTPRequest(method: "POST", path: "/", headers: [(name: "content-type", value: "application/json; charset=utf-8")])))
    expect(ControlValidation.requireJSON(HTTPRequest(method: "POST", path: "/"))?.status, 415)
    expect(ControlValidation.requireJSON(HTTPRequest(method: "POST", path: "/", headers: [(name: "Content-Type", value: "text/plain")]))?.status, 415)
}

func createBody(_ json: String) -> Result<ForwardRequest, ControlAPIError> {
    ControlValidation.decode(CreateForwardBody.self, from: Data(json.utf8)).flatMap(ControlValidation.validateCreate)
}

func createStatus(_ json: String) -> Int {
    if case .failure(let error) = createBody(json) { return error.status }
    return 0
}

test("controlValidateCreate") {
    // JSON escape \u0007 (BEL) must be stripped from hints
    expect(createBody(#"{"app":"someapp","remote_port":4980,"hint":" PR #1\u0007 "}"#),
           .success(ForwardRequest(app: "someapp", remotePort: 4980, forwardHost: "localhost", localPort: nil, hint: "PR #1")))
    expect(createBody(#"{"app":"someapp","remote_port":80,"local_port":8080,"forward_host":"db.internal"}"#),
           .success(ForwardRequest(app: "someapp", remotePort: 80, forwardHost: "db.internal", localPort: 8080)))
    expect(createStatus(#"{"app":"SomeApp","remote_port":1}"#), 400)
    expect(createStatus(#"{"app":"someapp","remote_port":0}"#), 400)
    expect(createStatus(#"{"app":"someapp","remote_port":70000}"#), 400)
    expect(createStatus(#"{"app":"someapp","remote_port":1,"local_port":0}"#), 400)
    expect(createStatus(#"{"app":"someapp","remote_port":1,"forward_host":"a b"}"#), 400)
    expect(createStatus(#"{"app":"someapp","remote_port":1,"hint":""# + String(repeating: "x", count: 201) + #""}"#), 400)
    expect(createStatus(#"{"remote_port":1}"#), 400)
    expect(createStatus("not json"), 400)
}

// MARK: - Control: matching

let devbox = ControlHostIdentity(name: "devbox", sshHost: "devbox", sshUser: nil, sshPort: nil)
let owner1 = ControlOwner(name: "devbox", generation: 1)

func candidate(
    _ id: String, source: TunnelSource = .config, mode: TunnelMode = .local, sshHost: String = "devbox",
    sshUser: String? = nil, sshPort: UInt16? = nil, forwardHost: String = "localhost", remotePort: UInt16 = 4970,
    localPort: UInt16 = 4970, owner: ControlOwner? = nil, isActive: Bool = false
) -> ForwardCandidate {
    ForwardCandidate(id: id, source: source, mode: mode, sshHost: sshHost, sshUser: sshUser, sshPort: sshPort,
                     forwardHost: forwardHost, remotePort: remotePort, localPort: localPort, owner: owner, isActive: isActive)
}

test("matcherReusesConfigLocalOnly") {
    let req = ForwardRequest(app: "someapp", remotePort: 4970)
    expect(ForwardMatcher.resolve(req, candidates: [candidate("someapp-a")], identity: devbox, owner: owner1), .reuseConfig(id: "someapp-a"))
    // Remote mode never matches
    expect(ForwardMatcher.resolve(req, candidates: [candidate("expose", mode: .remote)], identity: devbox, owner: owner1), .none)
    // Different SSH identity never matches
    expect(ForwardMatcher.resolve(req, candidates: [candidate("u", sshUser: "other")], identity: devbox, owner: owner1), .none)
    expect(ForwardMatcher.resolve(req, candidates: [candidate("p", sshPort: 2222)], identity: devbox, owner: owner1), .none)
    expect(ForwardMatcher.resolve(req, candidates: [candidate("h", sshHost: "elsewhere")], identity: devbox, owner: owner1), .none)
    // Explicit local port is ignored for config reuse
    let explicit = ForwardRequest(app: "someapp", remotePort: 4970, localPort: 9999)
    expect(ForwardMatcher.resolve(explicit, candidates: [candidate("someapp-a")], identity: devbox, owner: owner1), .reuseConfig(id: "someapp-a"))
}

test("matcherPrefersActiveThenId") {
    let req = ForwardRequest(app: "someapp", remotePort: 4970)
    let list = [candidate("b"), candidate("c", isActive: true), candidate("a")]
    expect(ForwardMatcher.resolve(req, candidates: list, identity: devbox, owner: owner1), .reuseConfig(id: "c"))
    let inactive = [candidate("b"), candidate("a")]
    expect(ForwardMatcher.resolve(req, candidates: inactive, identity: devbox, owner: owner1), .reuseConfig(id: "a"))
}

test("matcherDynamicOwnershipAndConflict") {
    let dyn = candidate("dyn:1", source: .dynamic, localPort: 5000, owner: owner1)
    let auto = ForwardRequest(app: "someapp", remotePort: 4970)
    expect(ForwardMatcher.resolve(auto, candidates: [dyn], identity: devbox, owner: owner1), .reuseDynamic(id: "dyn:1"))
    let same = ForwardRequest(app: "someapp", remotePort: 4970, localPort: 5000)
    expect(ForwardMatcher.resolve(same, candidates: [dyn], identity: devbox, owner: owner1), .reuseDynamic(id: "dyn:1"))
    let different = ForwardRequest(app: "someapp", remotePort: 4970, localPort: 5001)
    expect(ForwardMatcher.resolve(different, candidates: [dyn], identity: devbox, owner: owner1), .conflict(id: "dyn:1", localPort: 5000))
    // An old generation or another host cannot see the entry
    let owner2 = ControlOwner(name: "devbox", generation: 2)
    expect(ForwardMatcher.resolve(auto, candidates: [dyn], identity: devbox, owner: owner2), .none)
    expect(ForwardMatcher.isVisible(dyn, identity: devbox, owner: owner2), false)
    expect(ForwardMatcher.isVisible(dyn, identity: devbox, owner: ControlOwner(name: "other", generation: 1)), false)
    // A different destination does not match
    let otherHost = ForwardRequest(app: "someapp", remotePort: 4970, forwardHost: "db")
    expect(ForwardMatcher.resolve(otherHost, candidates: [dyn], identity: devbox, owner: owner1), .none)
}

// MARK: - Control: approvals

test("approvalMergeAndResolveOnce") {
    var registry = ApprovalRegistry(maxPendingPerOwner: 3, denyCacheDuration: 60)
    let now = Date()
    let key = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1))
    let w1 = UUID(), w2 = UUID()
    guard case .created(let id) = registry.submit(key: key, hint: "a", waiter: w1, now: now) else { throw TestError("expected created") }
    expect(registry.submit(key: key, hint: "b", waiter: w2, now: now), .joined(id))
    expect(registry.pending[id]?.hint, "b")
    expect(registry.resolve(id, outcome: .allowed, now: now), [w1, w2])
    expectNil(registry.resolve(id, outcome: .denied, now: now))
}

test("approvalDifferentLocalPortNotMerged") {
    var registry = ApprovalRegistry()
    let now = Date()
    let a = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1, localPort: 10))
    let b = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1, localPort: 11))
    let c = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1))
    guard case .created = registry.submit(key: a, hint: nil, waiter: UUID(), now: now),
          case .created = registry.submit(key: b, hint: nil, waiter: UUID(), now: now),
          case .created = registry.submit(key: c, hint: nil, waiter: UUID(), now: now) else {
        throw TestError("expected separate approvals")
    }
    expect(registry.pending.count, 3)
}

test("approvalWaiterRemovalAndLimits") {
    var registry = ApprovalRegistry(maxPendingPerOwner: 2, denyCacheDuration: 60)
    let now = Date()
    let key = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1))
    let w1 = UUID(), w2 = UUID()
    guard case .created(let id) = registry.submit(key: key, hint: nil, waiter: w1, now: now) else { throw TestError("created") }
    _ = registry.submit(key: key, hint: nil, waiter: w2, now: now)
    expect(registry.removeWaiter(w1, from: id), false)
    expect(registry.pending[id]?.waiters, [w2])
    expect(registry.removeWaiter(w2, from: id), true)
    expectNil(registry.pending[id])

    _ = registry.submit(key: ApprovalKey(owner: owner1, request: ForwardRequest(app: "a", remotePort: 1)), hint: nil, waiter: UUID(), now: now)
    _ = registry.submit(key: ApprovalKey(owner: owner1, request: ForwardRequest(app: "b", remotePort: 1)), hint: nil, waiter: UUID(), now: now)
    expect(registry.submit(key: ApprovalKey(owner: owner1, request: ForwardRequest(app: "c", remotePort: 1)), hint: nil, waiter: UUID(), now: now), .limitExceeded)
    // Another owner has its own budget
    let other = ControlOwner(name: "other", generation: 3)
    guard case .created = registry.submit(key: ApprovalKey(owner: other, request: ForwardRequest(app: "c", remotePort: 1)), hint: nil, waiter: UUID(), now: now) else {
        throw TestError("expected created for other owner")
    }
    let cancelled = registry.cancel { $0.key.owner == owner1 }
    expect(cancelled.count, 2)
    expect(registry.pending.count, 1)
}

test("approvalDenyCache") {
    var registry = ApprovalRegistry(maxPendingPerOwner: 3, denyCacheDuration: 60)
    let now = Date()
    let key = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1))
    guard case .created(let id) = registry.submit(key: key, hint: nil, waiter: UUID(), now: now) else { throw TestError("created") }
    _ = registry.resolve(id, outcome: .denied, now: now)
    expect(registry.submit(key: key, hint: nil, waiter: UUID(), now: now.addingTimeInterval(30)), .deniedRecently)
    guard case .created = registry.submit(key: key, hint: nil, waiter: UUID(), now: now.addingTimeInterval(61)) else {
        throw TestError("deny cache should expire")
    }
    // Timeouts are not cached as denials
    var other = ApprovalRegistry()
    guard case .created(let id2) = other.submit(key: key, hint: nil, waiter: UUID(), now: now) else { throw TestError("created") }
    _ = other.resolve(id2, outcome: .timedOut, now: now)
    guard case .created = other.submit(key: key, hint: nil, waiter: UUID(), now: now) else { throw TestError("timeout must not be cached") }
}

test("approvalPromptRateLimit") {
    var registry = ApprovalRegistry(maxPendingPerOwner: 10, denyCacheDuration: 60, maxPromptsPerWindow: 2, promptWindow: 100)
    let now = Date()
    func request(_ port: UInt16) -> ApprovalKey { ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: port)) }

    // A client that disconnects (cancelling the prompt) still used up a prompt
    guard case .created(let id) = registry.submit(key: request(1), hint: nil, waiter: UUID(), now: now) else { throw TestError("created") }
    _ = registry.cancel { $0.id == id }
    guard case .created = registry.submit(key: request(2), hint: nil, waiter: UUID(), now: now) else { throw TestError("created") }
    expect(registry.submit(key: request(3), hint: nil, waiter: UUID(), now: now.addingTimeInterval(50)), .rateLimited)
    // Joining an existing prompt is not a new prompt
    guard case .joined = registry.submit(key: request(2), hint: nil, waiter: UUID(), now: now.addingTimeInterval(50)) else { throw TestError("joined") }
    // Other owners have their own budget
    let other = ControlOwner(name: "other", generation: 3)
    guard case .created = registry.submit(key: ApprovalKey(owner: other, request: ForwardRequest(app: "a", remotePort: 1)), hint: nil, waiter: UUID(), now: now) else {
        throw TestError("expected created for other owner")
    }
    // The window slides
    guard case .created = registry.submit(key: request(3), hint: nil, waiter: UUID(), now: now.addingTimeInterval(101)) else { throw TestError("window should expire") }
}

test("forwardErrorCodes") {
    expect(ForwardErrorCode(message: "Host key verification failed."), .hostKeyMismatch)
    expect(ForwardErrorCode(message: "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nOffending key in /Users/u/.ssh/known_hosts:3"), .hostKeyMismatch)
    expect(ForwardErrorCode(message: "u@devbox: Permission denied (publickey)."), .authFailed)
    expect(ForwardErrorCode(message: "Error: remote port forwarding failed for listen port 4980"), .forwardFailed)
    expect(ForwardErrorCode(message: "bind [127.0.0.1]:4980: Address already in use"), .forwardFailed)
    expect(ForwardErrorCode(message: "ssh: Could not resolve hostname devbox: nodename nor servname provided"), .connectFailed)
    expect(ForwardErrorCode(message: "ssh: connect to host devbox port 22: Connection refused"), .connectFailed)
    expect(ForwardErrorCode(message: "SSH exited with code 255"), .sshFailed)
    expect(ForwardErrorCode(message: "Failed to run ssh: launch path not accessible"), .sshFailed)
    // The view carries the code, never the raw text
    let info = TunnelInfo(id: "t", status: .error, mode: .local, localPort: 1, remotePort: 2, sshHost: "h",
                          errorMessage: "Offending key in /Users/u/.ssh/known_hosts:3")
    let json = String(data: (try? JSONEncoder().encode(ForwardView(info: info))) ?? Data(), encoding: .utf8) ?? ""
    expect(json.contains("host_key_mismatch"), true)
    expect(json.contains("known_hosts"), false)
}

test("approvalDenialListingAndClearing") {
    var registry = ApprovalRegistry(maxPendingPerOwner: 3, denyCacheDuration: 60)
    let now = Date()
    let key = ApprovalKey(owner: owner1, request: ForwardRequest(app: "someapp", remotePort: 1))
    guard case .created(let id) = registry.submit(key: key, hint: "PR #1", waiter: UUID(), now: now) else { throw TestError("created") }
    _ = registry.resolve(id, outcome: .denied, now: now)

    let denials = registry.recentDenials(now: now)
    expect(denials.map(\.key), [key])
    expect(denials.first?.hint, "PR #1")
    expect(registry.recentDenials(now: now.addingTimeInterval(61)).count, 0)

    // Clearing lets the same request prompt again
    expect(registry.clearDenial(key), true)
    expect(registry.clearDenial(key), false)
    guard case .created = registry.submit(key: key, hint: nil, waiter: UUID(), now: now) else {
        throw TestError("cleared denial should allow a new prompt")
    }

    // Denials of a revoked owner are forgotten
    var other = ApprovalRegistry()
    let otherOwner = ControlOwner(name: "other", generation: 9)
    let otherKey = ApprovalKey(owner: otherOwner, request: ForwardRequest(app: "someapp", remotePort: 2))
    for k in [key, otherKey] {
        guard case .created(let pid) = other.submit(key: k, hint: nil, waiter: UUID(), now: now) else { throw TestError("created") }
        _ = other.resolve(pid, outcome: .denied, now: now)
    }
    other.clearDenials { $0.owner == owner1 }
    expect(other.recentDenials(now: now).map(\.key), [otherKey])
}

// MARK: - Control: paths and ssh arguments

test("socketPathValidation") {
    expect(ControlPaths.isSafeSocketPath("/home/user/.larimar/control.sock"), true)
    expect(ControlPaths.isSafeSocketPath("/var/folders/9x/ab_cd/T/larimar-control/0123456789abcdef.sock"), true)
    expect(ControlPaths.isSafeSocketPath("relative/control.sock"), false)
    for bad in ["/home/a b/x", "/home/a:b/x", "/home/a\\b/x", "/home/$USER/x", "/home/~/x", "/home/a" + CRLF + "b/x"] {
        expect(ControlPaths.isSafeSocketPath(bad), false, bad)
    }
    // 103 bytes + NUL fits, 104 bytes does not
    let fits = "/" + String(repeating: "a", count: 102)
    let tooLong = "/" + String(repeating: "a", count: 103)
    expect(ControlPaths.isSafeSocketPath(fits), true)
    expect(ControlPaths.isSafeSocketPath(tooLong), false)
}

test("remoteSocketPathFromPrepOutput") {
    expect(ControlPaths.remoteSocketPath(fromPrepOutput: "/home/user/.larimar"), "/home/user/.larimar/control.sock")
    expectNil(ControlPaths.remoteSocketPath(fromPrepOutput: ""))
    expectNil(ControlPaths.remoteSocketPath(fromPrepOutput: ".larimar"))
    expectNil(ControlPaths.remoteSocketPath(fromPrepOutput: "/home/user/.larimar/"))
    expectNil(ControlPaths.remoteSocketPath(fromPrepOutput: "/home/us er/.larimar"))
    // The directory fits alone but the final path would exceed the limit
    let dir = "/" + String(repeating: "a", count: 95)
    expectNil(ControlPaths.remoteSocketPath(fromPrepOutput: dir))
}

test("macSocketFileNameBoundToIdentityAndGeneration") {
    let a = ControlPaths.macSocketFileName(identity: devbox, generation: 1)
    expect(a.count, 21)
    expect(a.hasSuffix(".sock"), true)
    expect(a == ControlPaths.macSocketFileName(identity: devbox, generation: 2), false)
    let changed = ControlHostIdentity(name: "devbox", sshHost: "devbox2")
    expect(a == ControlPaths.macSocketFileName(identity: changed, generation: 1), false)
    expect(a, ControlPaths.macSocketFileName(identity: devbox, generation: 1))
}

test("sshCommandArguments") {
    let tunnel = SSHCommand.forwardingArguments(forward: ["-L", "127.0.0.1:1:localhost:2"], sshHost: "devbox", sshUser: "u", sshPort: 2222)
    expect(Array(tunnel.prefix(3)), ["-N", "-L", "127.0.0.1:1:localhost:2"])
    expect(tunnel.contains("ControlPath=none"), true)
    expect(tunnel.contains("ControlMaster=no"), true)
    expect(tunnel.contains("ForkAfterAuthentication=no"), true)
    expect(tunnel.contains("ExitOnForwardFailure=yes"), true)
    expect(tunnel.contains("PermitLocalCommand=yes"), true)
    expect(tunnel.contains("LocalCommand=echo \(SSHCommand.readyMarker)"), true)
    expect(Array(tunnel.suffix(5)), ["-l", "u", "-p", "2222", "devbox"])

    let prep = SSHCommand.prepArguments(identity: devbox)
    expect(Array(prep.suffix(3)), ["devbox", "sh", "-s"])
    expect(prep.contains("-N"), false)
    expect(prep.contains("ControlPath=none"), true)

    let control = SSHCommand.controlArguments(identity: devbox, remoteSocket: "/home/u/.larimar/control.sock", macSocket: "/tmp/x.sock")
    expect(Array(control.prefix(3)), ["-N", "-R", "/home/u/.larimar/control.sock:/tmp/x.sock"])
    expect(control.last, "devbox")
}

test("sshReadyMarkerSplitAcrossWrites") {
    let pipe = Pipe()
    let ready = DispatchSemaphore(value: 0)
    SSHCommand.watchReady(stdout: pipe) { ready.signal() }
    let writer = pipe.fileHandleForWriting
    writer.write(Data("larimar-".utf8))
    expect(ready.wait(timeout: .now() + 0.2), .timedOut)
    writer.write(Data("ready\n".utf8))
    expect(ready.wait(timeout: .now() + 2), .success)
    try? writer.close()
}

test("reconnectBackoff") {
    expect(ReconnectBackoff.delay(retryCount: 0, jitter: 0), 1.0)
    expect(ReconnectBackoff.delay(retryCount: 3, jitter: 0), 8.0)
    expect(ReconnectBackoff.delay(retryCount: 20, jitter: 0), 300.0)
    expect(ReconnectBackoff.delay(retryCount: 0, jitter: -0.25), 1.0)
}

// MARK: - Control: grouping and IPC compatibility

test("menuGrouping") {
    let infos = [
        TunnelInfo(id: "someapp-2", status: .stopped, localPort: 4971, remotePort: 4971, sshHost: "h", app: "someapp"),
        TunnelInfo(id: "someapp-1", status: .stopped, localPort: 4970, remotePort: 4970, sshHost: "h", app: "someapp"),
        TunnelInfo(id: "web", status: .stopped, localPort: 5432, remotePort: 5432, sshHost: "h"),
        TunnelInfo(id: "dyn:1", status: .stopped, localPort: 4980, remotePort: 4980, sshHost: "h", source: .dynamic, app: "otherapp"),
    ]
    let configured = MenuGrouping.groups(infos, source: .config)
    expect(configured.map(\.id), ["app:someapp", "tunnel:web"])
    if case .app(_, let tunnels) = configured[0] {
        expect(tunnels.map(\.id), ["someapp-1", "someapp-2"])
    } else {
        throw TestError("expected app group")
    }
    expect(MenuGrouping.groups(infos, source: .dynamic).map(\.id), ["app:otherapp"])
}

test("ipcBackwardCompatibleDecoding") {
    let json = #"{"id":"x","success":true,"data":{"tunnels":[{"id":"web","status":"stopped","localPort":1,"remotePort":2,"sshHost":"h"}]}}"#
    let response = try JSONDecoder().decode(IPCResponse.self, from: Data(json.utf8))
    let info = response.data!.tunnels[0]
    expect(info.source, .config)
    expectNil(info.app)
    expectNil(info.hint)
    expectNil(info.owner)
    expect(info.forwardHost, "localhost")
    expectNil(response.data!.controls)
}

test("ipcNewCommandsRoundTrip") {
    let commands: [IPCCommand] = [
        .remove(tunnelId: "dyn:1"),
        .setHint(tunnelId: "someapp-1", hint: "PR #1"),
        .setHint(tunnelId: "someapp-1", hint: nil),
        .connectControl(name: "devbox"),
        .disconnectControl(name: "devbox"),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    for command in commands {
        let data = try encoder.encode(IPCRequest(id: "r", command: command))
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        let reencoded = try encoder.encode(decoded)
        expect(String(data: reencoded, encoding: .utf8), String(data: data, encoding: .utf8))
    }
    let data = try JSONEncoder().encode(IPCResponseData(
        tunnels: [TunnelInfo(id: "dyn:1", status: .connected, localPort: 1, remotePort: 1, sshHost: "h", source: .dynamic, app: "someapp", hint: "x", owner: "devbox")],
        controls: [ControlInfo(name: "devbox", sshHost: "h", status: .preparing)]
    ))
    let decoded = try JSONDecoder().decode(IPCResponseData.self, from: data)
    expect(decoded.tunnels[0].source, .dynamic)
    expect(decoded.tunnels[0].owner, "devbox")
    expect(decoded.controls?.first?.status, .preparing)
}

// MARK: - Summary

print("\n\(passed) passed, \(failures) failed")
if failures > 0 {
    exit(1)
}

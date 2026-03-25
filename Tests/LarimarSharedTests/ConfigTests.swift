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
    expect(result.warnings[0], "tunnel 'web': unknown mode 'bogus'")
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

// MARK: - Summary

print("\n\(passed) passed, \(failures) failed")
if failures > 0 {
    exit(1)
}

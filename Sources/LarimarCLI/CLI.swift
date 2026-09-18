import ArgumentParser
import Foundation
import LarimarShared

struct LarimarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "larimar",
        abstract: "CLI for Larimar SSH tunnel manager",
        version: LarimarVersion.current,
        subcommands: [Status.self, Connect.self, Disconnect.self, List.self, Remove.self, Hint.self, Control.self, Version.self]
    )
}

/// Custom entry point so that everything ArgumentParser itself prints — help,
/// `--version`, usage and validation errors — comes out as JSON like the rest
/// of the CLI. The only exception is `--generate-completion-script`, whose
/// output is shell code meant to be sourced.
@main
struct Main {
    static func main() async {
        do {
            var command = try LarimarCLI.parseAsRoot()
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch let exit as ExitCode {
            // The command already printed its JSON output.
            Foundation.exit(exit.rawValue)
        } catch {
            let code = LarimarCLI.exitCode(for: error)
            guard code != .success else {
                // Help, `--version` and completion scripts are requests, not failures.
                let text = LarimarCLI.fullMessage(for: error)
                if CommandLine.arguments.contains("--generate-completion-script") {
                    LarimarCLI.exit(withError: error)
                } else if text == LarimarVersion.current {
                    emit(CLIOutput(version: text))
                } else {
                    emit(CLIOutput(help: text))
                }
                Foundation.exit(0)
            }
            emit(.failure(LarimarCLI.message(for: error)))
            Foundation.exit(code.rawValue)
        }
    }
}

// MARK: - Status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show tunnel status"
    )

    func run() async throws {
        let data = try await request(.status)
        emit(CLIOutput(tunnels: data.tunnels, controls: data.controls))
    }
}

// MARK: - Connect

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect a tunnel (or all tunnels with --all)"
    )

    @Flag(name: .long, help: "Connect all tunnels")
    var all = false

    @Flag(name: .long, help: "Return as soon as the connection is requested")
    var noWait = false

    @Option(name: .long, help: "Seconds to wait for the connection to be established")
    var timeout: Double = 60

    @Argument(help: "Tunnel ID to connect")
    var tunnelId: String?

    func validate() throws {
        if !all && tunnelId == nil {
            throw ValidationError("Provide a tunnel ID or use --all")
        }
        if timeout <= 0 {
            throw ValidationError("--timeout must be greater than 0")
        }
    }

    func run() async throws {
        let command: IPCCommand = all ? .connectAll : .connect(tunnelId: tunnelId!)
        let data = try await request(command)
        let targets = all ? data.tunnels : data.tunnels.filter { $0.id == tunnelId! }
        guard !noWait else {
            emit(CLIOutput(tunnels: targets))
            return
        }
        try await waitUntilSettled(
            tunnelIds: targets.filter { $0.status.isActive }.map(\.id),
            timeout: timeout
        )
    }
}

/// Polls the daemon until every requested tunnel has connected or failed.
///
/// A failed attempt leaves the tunnel in `error`, or — when auto-reconnect keeps
/// retrying in the background — in `reconnecting` and then back in `connecting`
/// with the previous error still attached. Since `connect` clears the error
/// before the first attempt, a `connecting` tunnel that carries one has already
/// failed at least once, so the command reports it instead of waiting out the
/// whole backoff.
private func waitUntilSettled(tunnelIds: [String], timeout: Double) async throws {
    let pollInterval = Duration.milliseconds(250)
    let deadline = ContinuousClock.now + .seconds(timeout)
    let waitingFor = Set(tunnelIds)

    while true {
        let targets = try await request(.status).tunnels.filter { waitingFor.contains($0.id) }
        let pending = targets.filter { $0.status == .connecting && $0.errorMessage == nil }
        let pendingIds = Set(pending.map(\.id))
        let failed = targets.filter { $0.status != .connected && !pendingIds.contains($0.id) }

        guard failed.isEmpty else {
            emit(CLIOutput(
                success: false,
                tunnels: targets,
                error: "Failed to connect: " + failed.map { describeFailure($0) }.joined(separator: ", ")
            ))
            throw ExitCode.failure
        }
        if pending.isEmpty {
            emit(CLIOutput(tunnels: targets))
            return
        }

        guard ContinuousClock.now < deadline else {
            emit(CLIOutput(
                success: false,
                tunnels: targets,
                error: "Timed out after \(Int(timeout))s waiting for: " + pending.map(\.id).joined(separator: ", ")
            ))
            throw ExitCode.failure
        }
        try await Task.sleep(for: pollInterval)
    }
}

private func describeFailure(_ tunnel: TunnelInfo) -> String {
    guard let message = tunnel.errorMessage else { return "\(tunnel.id) (\(tunnel.status.rawValue))" }
    return "\(tunnel.id) (\(tunnel.status.rawValue): \(singleLine(message)))"
}

/// Collapse multi-line ssh stderr so an error message stays on one line.
private func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

// MARK: - Disconnect

struct Disconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Disconnect a tunnel (or all tunnels with --all)"
    )

    @Flag(name: .long, help: "Disconnect all tunnels")
    var all = false

    @Argument(help: "Tunnel ID to disconnect")
    var tunnelId: String?

    func validate() throws {
        if !all && tunnelId == nil {
            throw ValidationError("Provide a tunnel ID or use --all")
        }
    }

    func run() async throws {
        let command: IPCCommand = all ? .disconnectAll : .disconnect(tunnelId: tunnelId!)
        let data = try await request(command)
        emit(CLIOutput(tunnels: all ? data.tunnels : data.tunnels.filter { $0.id == tunnelId! }))
    }
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List configured tunnels"
    )

    func run() async throws {
        emit(CLIOutput(tunnels: try await request(.list).tunnels))
    }
}

// MARK: - Remove

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a dynamic tunnel"
    )

    @Argument(help: "Dynamic tunnel ID (e.g. dyn:1a2b3c4d)")
    var tunnelId: String

    func run() async throws {
        _ = try await request(.remove(tunnelId: tunnelId))
        emit(CLIOutput(removed: tunnelId))
    }
}

// MARK: - Hint

struct Hint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set or clear the hint shown for a tunnel"
    )

    @Flag(name: .long, help: "Clear the hint")
    var clear = false

    @Argument(help: "Tunnel ID")
    var tunnelId: String

    @Argument(help: "Hint text")
    var text: String?

    func validate() throws {
        if clear == (text != nil) {
            throw ValidationError("Provide hint text or use --clear")
        }
    }

    func run() async throws {
        let data = try await request(.setHint(tunnelId: tunnelId, hint: clear ? nil : text))
        emit(CLIOutput(tunnels: data.tunnels.filter { $0.id == tunnelId }))
    }
}

// MARK: - Control

struct Control: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage control connections for remote forward requests",
        subcommands: [ControlConnect.self, ControlDisconnect.self]
    )
}

struct ControlConnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect the control connection of a host"
    )

    @Argument(help: "Control host name")
    var name: String

    func run() async throws {
        let data = try await request(.connectControl(name: name))
        emit(CLIOutput(controls: (data.controls ?? []).filter { $0.name == name }))
    }
}

struct ControlDisconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Disconnect the control connection of a host"
    )

    @Argument(help: "Control host name")
    var name: String

    func run() async throws {
        let data = try await request(.disconnectControl(name: name))
        emit(CLIOutput(controls: (data.controls ?? []).filter { $0.name == name }))
    }
}

// MARK: - Version

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show Larimar version"
    )

    func run() {
        emit(CLIOutput(version: LarimarVersion.current))
    }
}

// MARK: - Output

/// The CLI is consumed by scripts and coding agents, so every command prints a
/// single JSON object on stdout. Failures print `{"success": false, "error": ...}`
/// and exit non-zero.
private struct CLIOutput: Encodable {
    var success = true
    var tunnels: [TunnelInfo]?
    var controls: [ControlInfo]?
    var removed: String?
    var version: String?
    var help: String?
    var error: String?

    static func failure(_ error: String) -> CLIOutput {
        CLIOutput(success: false, error: error)
    }
}

/// Sends a command to the daemon, reporting any failure as JSON and exiting.
private func request(_ command: IPCCommand) async throws -> IPCResponseData {
    let response: IPCResponse
    do {
        response = try await IPCClient.send(command)
    } catch {
        emit(.failure(String(describing: error)))
        throw ExitCode.failure
    }

    guard response.success, let data = response.data else {
        emit(.failure(response.error ?? "Unknown error"))
        throw ExitCode.failure
    }
    return data
}

private func emit(_ output: CLIOutput) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(output), let json = String(data: data, encoding: .utf8) else {
        print(#"{"success": false, "error": "Failed to encode response"}"#)
        return
    }
    print(json)
}

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

/// Custom entry point so that usage and validation errors are reported as JSON
/// like every other failure. Help and `--version` keep ArgumentParser's own
/// plain-text output, since those are read by humans.
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
                // Help and `--version` are requests, not failures.
                LarimarCLI.exit(withError: error)
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
        try await sendAndPrint(.status)
    }
}

// MARK: - Connect

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect a tunnel (or all tunnels with --all)"
    )

    @Flag(name: .long, help: "Connect all tunnels")
    var all = false

    @Argument(help: "Tunnel ID to connect")
    var tunnelId: String?

    func validate() throws {
        if !all && tunnelId == nil {
            throw ValidationError("Provide a tunnel ID or use --all")
        }
    }

    func run() async throws {
        let command: IPCCommand = all ? .connectAll : .connect(tunnelId: tunnelId!)
        try await sendAndPrint(command)
    }
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
        try await sendAndPrint(command)
    }
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List configured tunnels"
    )

    func run() async throws {
        try await sendAndPrint(.list)
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
        try await sendAndPrint(.remove(tunnelId: tunnelId))
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
        try await sendAndPrint(.setHint(tunnelId: tunnelId, hint: clear ? nil : text))
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
        try await sendAndPrint(.connectControl(name: name))
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
        try await sendAndPrint(.disconnectControl(name: name))
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
    var version: String?
    var error: String?

    static func failure(_ error: String) -> CLIOutput {
        CLIOutput(success: false, error: error)
    }
}

private func sendAndPrint(_ command: IPCCommand) async throws {
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
    emit(CLIOutput(tunnels: data.tunnels, controls: data.controls))
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

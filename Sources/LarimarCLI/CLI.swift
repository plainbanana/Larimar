import ArgumentParser
import Foundation
import LarimarShared

@main
struct LarimarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "larimar",
        abstract: "CLI for Larimar SSH tunnel manager",
        version: LarimarVersion.current,
        subcommands: [Status.self, Connect.self, Disconnect.self, List.self, Remove.self, Hint.self, Control.self, Version.self]
    )
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
        try await sendAndPrint(command, showControls: false)
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
        try await sendAndPrint(command, showControls: false)
    }
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List configured tunnels"
    )

    func run() async throws {
        try await sendAndPrint(.list, showControls: false)
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
        print(LarimarVersion.current)
    }
}

// MARK: - Output Helpers

private func sendAndPrint(_ command: IPCCommand, showControls: Bool = true) async throws {
    let response = try await IPCClient.send(command)
    guard response.success, let data = response.data else {
        printError(response.error ?? "Unknown error")
        throw ExitCode.failure
    }
    printTunnelTable(data.tunnels)
    if showControls {
        printControlTable(data.controls ?? [])
    }
}

private func printTunnelTable(_ tunnels: [TunnelInfo]) {
    if tunnels.isEmpty {
        print("No tunnels configured.")
        return
    }

    for tunnel in tunnels {
        let statusStr = tunnel.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
        let portStr: String
        switch tunnel.mode {
        case .local:
            portStr = "-L :\(tunnel.localPort)"
        case .remote:
            portStr = "-R :\(tunnel.remotePort)"
        case .dynamic:
            portStr = "-D :\(tunnel.localPort)"
        }
        let sourceStr = tunnel.source.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let appStr = (tunnel.app ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
        var line = "  \(tunnel.status.icon) \(tunnel.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(statusStr) \(sourceStr) \(appStr) \(portStr.padding(toLength: 10, withPad: " ", startingAt: 0))"
        if let hint = tunnel.hint {
            line += "  \(hint)"
        }
        if let err = tunnel.errorMessage {
            line += "  (\(singleLine(err)))"
        }
        print(line)
    }
}

private func printControlTable(_ controls: [ControlInfo]) {
    guard !controls.isEmpty else { return }
    print("\nControl:")
    for control in controls {
        var line = "  \(control.status.icon) \(control.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(control.status.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(control.sshHost)"
        if let err = control.errorMessage {
            line += "  (\(singleLine(err)))"
        }
        print(line)
    }
}

/// Collapse multi-line ssh stderr so each table row stays on one line.
private func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

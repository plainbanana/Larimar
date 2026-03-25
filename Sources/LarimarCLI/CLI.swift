import ArgumentParser
import Foundation
import LarimarShared

@main
struct LarimarCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "larimar",
        abstract: "CLI for Larimar SSH tunnel manager",
        subcommands: [Status.self, Connect.self, Disconnect.self, List.self]
    )
}

// MARK: - Status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show tunnel status"
    )

    func run() async throws {
        let response = try await IPCClient.send(.status)
        guard response.success, let data = response.data else {
            printError(response.error ?? "Unknown error")
            throw ExitCode.failure
        }
        printTunnelTable(data.tunnels)
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
        let response = try await IPCClient.send(command)
        guard response.success, let data = response.data else {
            printError(response.error ?? "Unknown error")
            throw ExitCode.failure
        }
        printTunnelTable(data.tunnels)
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
        let response = try await IPCClient.send(command)
        guard response.success, let data = response.data else {
            printError(response.error ?? "Unknown error")
            throw ExitCode.failure
        }
        printTunnelTable(data.tunnels)
    }
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List configured tunnels"
    )

    func run() async throws {
        let response = try await IPCClient.send(.list)
        guard response.success, let data = response.data else {
            printError(response.error ?? "Unknown error")
            throw ExitCode.failure
        }
        printTunnelTable(data.tunnels)
    }
}

// MARK: - Output Helpers

private func printTunnelTable(_ tunnels: [TunnelInfo]) {
    if tunnels.isEmpty {
        print("No tunnels configured.")
        return
    }

    for tunnel in tunnels {
        let icon: String
        switch tunnel.status {
        case .connected: icon = "●"
        case .connecting: icon = "◐"
        case .reconnecting: icon = "◐"
        case .stopped: icon = "○"
        case .error: icon = "✗"
        }

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
        var line = "  \(icon) \(tunnel.id.padding(toLength: 20, withPad: " ", startingAt: 0)) \(statusStr) \(portStr)"
        if let err = tunnel.errorMessage {
            line += "  (\(err))"
        }
        print(line)
    }
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

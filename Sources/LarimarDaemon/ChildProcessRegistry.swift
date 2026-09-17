import Foundation
import OSLog

/// Tracks every ssh child process so shutdown can wait for them to exit,
/// even after their owning tunnel has dropped its reference.
@MainActor
final class ChildProcessRegistry {
    static let shared = ChildProcessRegistry()

    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        prune()
        processes[ObjectIdentifier(process)] = process
    }

    /// Send SIGTERM to all running children, wait up to `grace` seconds,
    /// then SIGKILL whatever is left.
    func terminateAll(grace: TimeInterval) async {
        prune()
        for process in processes.values where process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            prune()
            if processes.isEmpty { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        prune()
        for process in processes.values where process.isRunning {
            Log.ssh.notice("Escalating to SIGKILL for pid=\(process.processIdentifier)")
            kill(process.processIdentifier, SIGKILL)
        }
        processes.removeAll()
    }

    private func prune() {
        processes = processes.filter { $0.value.isRunning }
    }
}

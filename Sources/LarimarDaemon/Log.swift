import OSLog
import LarimarShared

enum Log {
    static let daemon = Logger(subsystem: LarimarConstants.bundleIdentifier, category: "daemon")
    static let ipc    = Logger(subsystem: LarimarConstants.bundleIdentifier, category: "ipc")
    static let ssh    = Logger(subsystem: LarimarConstants.bundleIdentifier, category: "ssh")
    static let config = Logger(subsystem: LarimarConstants.bundleIdentifier, category: "config")
}

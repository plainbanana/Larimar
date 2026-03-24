import Foundation

public enum LarimarConstants {
    public static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Larimar")
    }()

    public static let socketPath: String = {
        appSupportDir.appendingPathComponent("larimar.sock").path
    }()

    public static let defaultConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/larimar/tunnels.toml").path
    }()

    public static let bundleIdentifier = "com.larimar.daemon"
}

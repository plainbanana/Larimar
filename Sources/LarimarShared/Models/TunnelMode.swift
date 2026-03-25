import Foundation

public enum TunnelMode: String, Codable, Sendable, Equatable {
    case local = "local"
    case remote = "remote"
    case dynamic = "dynamic"
}

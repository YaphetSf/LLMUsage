import Foundation

public struct RuntimeConfiguration: Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case server, client
    }

    public let role: Role
    public let serverURL: URL?
    public let serverName: String?
    public let keyFile: String?

    public init(role: Role, serverURL: URL? = nil, serverName: String? = nil, keyFile: String? = nil) {
        self.role = role
        self.serverURL = serverURL
        self.serverName = serverName
        self.keyFile = keyFile
    }

    public static let current: RuntimeConfiguration = {
        let path = ProcessInfo.processInfo.environment["LLMUSAGE_CONFIG"]
            ?? "~/.config/llmusage/runtime.json"
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self(role: .client) }
        return configuration
    }()
}

// Reads ~/.config/hasocket/{config.json,watch.json}.
import Foundation

public struct HAConfig {
    public let baseURL: String
    public let token: String

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum HAConfigStore {
    public static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hasocket/config.json")
    }

    public static var watchPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hasocket/watch.json")
    }

    public static func load() -> HAConfig? {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["base_url"] as? String,
              let token = obj["token"] as? String
        else { return nil }
        return HAConfig(baseURL: base, token: token)
    }

    public static func loadWatchedEntities() -> [String] {
        guard let data = try? Data(contentsOf: watchPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}

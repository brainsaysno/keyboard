import Foundation

/// Per-person settings from ~/.config/corne-companion/config.json, read once at start, so restart
/// the app after editing it. install.sh creates the file from config.example.json.
struct Config: Decodable {
    /// The GitHub repository the pull request counts come from, as "owner/name".
    var githubRepo: String?

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/corne-companion/config.json").path

    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path) else {
            log("No config at \(path); pull request counts stay at zero")
            return Config()
        }
        var config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log("Cannot read \(path): \(error); pull request counts stay at zero")
            return Config()
        }
        if let repo = config.githubRepo, repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) == nil {
            log("githubRepo \"\(repo)\" in \(path) is not \"owner/name\"; pull request counts stay at zero")
            config.githubRepo = nil
        } else if config.githubRepo == nil {
            log("githubRepo is not set in \(path); pull request counts stay at zero")
        }
        return config
    }
}

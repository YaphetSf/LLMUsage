import Foundation

/// Where OpenCode keeps its data on this machine. Resolution mirrors OpenCode itself:
/// `OPENCODE_DATA_DIR` wins, then `$XDG_DATA_HOME/opencode`, then `~/.local/share/opencode`.
public enum OpenCodePaths {
    public static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let override = environment["OPENCODE_DATA_DIR"]?.trimmed, !override.isEmpty {
            return expandingTilde(override, home: homeDirectory)
        }
        if let xdg = environment["XDG_DATA_HOME"]?.trimmed, !xdg.isEmpty {
            return expandingTilde(xdg, home: homeDirectory) + "/opencode"
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode").path
    }

    /// Every `opencode*.db` in the data dir. OpenCode partitions its database per release channel
    /// (`opencode.db` for stable, `opencode-next.db` for the preview line), so hardcoding the stable
    /// name would silently miss a user on `next`. The `.db` suffix excludes `-wal`/`-shm` sidecars.
    ///
    /// A missing directory is the normal "never installed OpenCode" case and returns `[]`. A
    /// directory that exists but cannot be listed rethrows, so broken access is never mistaken for
    /// absence.
    public static func databaseFiles(
        in dataDirectory: String,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: dataDirectory)
        } catch {
            guard fileManager.fileExists(atPath: dataDirectory) else { return [] }
            throw UsageHistoryError.logsUnreadable(error.localizedDescription)
        }
        return names
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted()
            .map { dataDirectory.trimmingTrailingSlashes + "/" + $0 }
    }

    private static func expandingTilde(_ path: String, home: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path.trimmingTrailingSlashes }
        return (home.path + path.dropFirst(1)).trimmingTrailingSlashes
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var trimmingTrailingSlashes: String {
        var value = self
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

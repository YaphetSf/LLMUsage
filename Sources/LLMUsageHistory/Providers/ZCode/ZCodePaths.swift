import Foundation

/// Where ZCode keeps its usage database on this machine.
///
/// ZCode's desktop app and its CLI share one engine and one store, `~/.zcode/cli/db/db.sqlite`;
/// the other database under `~/.zcode/v2` is the automation and task index and holds no tokens.
/// Only the observed location is probed — a future layout surfaces as "never installed" rather
/// than as a guess at an environment variable ZCode may not read.
public enum ZCodePaths {
    public static func databaseFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory.appendingPathComponent(".zcode/cli/db/db.sqlite").path
    }

    /// The database if it exists, otherwise nothing. A missing file is the normal
    /// "never installed ZCode" case.
    public static func databaseFiles(
        path: String,
        fileManager: FileManager = .default
    ) -> [String] {
        fileManager.fileExists(atPath: path) ? [path] : []
    }
}

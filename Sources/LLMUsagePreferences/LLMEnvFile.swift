import Foundation

public enum LLMEnvFile {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".keys/llm.env")

    /// A login item never runs zsh, so it reads the file `.zshrc` sources instead of inheriting it.
    public static func value(
        _ names: String...,
        file: URL = defaultURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fileValues = (try? String(contentsOf: file, encoding: .utf8)).map(parse) ?? [:]
        for source in [fileValues, environment] {
            for name in names {
                if let value = source[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("export ") {
                line = line.dropFirst("export ".count).drop(while: \.isWhitespace)
            }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let rest = line[line.index(after: equals)...]
            if let quote = rest.first, quote == "\"" || quote == "'" {
                values[String(line[..<equals])] = String(rest.dropFirst().prefix { $0 != quote })
            } else {
                values[String(line[..<equals])] = String(rest.prefix { !$0.isWhitespace })
            }
        }
        return values
    }
}

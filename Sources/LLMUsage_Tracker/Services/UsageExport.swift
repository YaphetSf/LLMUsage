import Foundation
import LLMUsagePreferences

/// The latest snapshot bundle as a file for other programs on this Mac; the Incandenza hub
/// serves it to the phone's widget. Its JSON is a contract of its own, so `ProviderSnapshot`'s
/// Codable form can change without breaking readers.
enum UsageExport {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LLMUsage/usage.json")

    struct Document: Encodable {
        let updatedAt: Date
        let providers: [Provider]
    }

    struct Provider: Encodable {
        let id: String
        let name: String
        let plan: String?
        let error: String?
        let lines: [Line]
    }

    struct Line: Encodable {
        let label: String
        let usedPercent: Int?
        let text: String?
        let resetsAt: Date?
        let windowIsActive: Bool?
    }

    static func document(_ snapshots: [ProviderSnapshot], at date: Date) -> Document {
        Document(updatedAt: date, providers: snapshots.map { snapshot in
            switch snapshot.result.asResult {
            case .success(let usage):
                Provider(id: snapshot.id, name: snapshot.displayName, plan: usage.plan, error: nil,
                         lines: usage.lines.map {
                             Line(label: $0.label, usedPercent: $0.percent, text: $0.text,
                                  resetsAt: $0.resetsAt, windowIsActive: $0.windowIsActive)
                         })
            case .failure(let error):
                Provider(id: snapshot.id, name: snapshot.displayName, plan: nil,
                         error: error.localizedDescription, lines: [])
            }
        })
    }

    static func data(_ snapshots: [ProviderSnapshot], at date: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document(snapshots, at: date))
    }

    static func write(_ snapshots: [ProviderSnapshot], at date: Date = Date(), to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(snapshots, at: date).write(to: url, options: .atomic)
    }
}

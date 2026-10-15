import Foundation

/// One account the tracker knows how to poll. The registry exists so the control center can
/// render — and re-enable — an account that has no snapshot, whether because the tracker has
/// not fetched yet or because the user turned the account off. It must stay in sync with the
/// provider list `LLMUsage_TrackerApp.main()` builds; `ProviderTrackingTests` guards that.
public enum KnownProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case zai
    case minimax

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .zai: "GLM"
        case .minimax: "MiniMax"
        }
    }
}

import Foundation

public enum UsageDisplayMode: String, CaseIterable, Codable, Sendable {
    /// Listed in the order the picker shows them: the default (`remaining`, "Glass Half Full")
    /// leads so a fresh install lands on Full rather than popping in on Empty.
    case remaining
    case used

    public var label: String {
        switch self {
        case .remaining: "Glass Half Full"
        case .used: "Glass Half Empty"
        }
    }

    /// Compact form for a segmented pill alongside the menu-bar mode cards. The cards render
    /// the actual perspective — the pill only needs enough to be unambiguous at a glance.
    public var shortLabel: String {
        switch self {
        case .remaining: "Full"
        case .used: "Empty"
        }
    }

    public func displayPercent(forUsed usedPercent: Int) -> Int {
        let used = min(100, max(0, usedPercent))
        return self == .used ? used : 100 - used
    }
}

/// Accent colour the whole app's metal is cast from. The default (`silver`) reproduces the
/// original chrome; every other choice re-tints the glass, gradients, and glow that `Brand`
/// paints, while selection state (pills, links, toggles) reads the same choice.
public enum AccentChoice: String, CaseIterable, Codable, Sendable {
    case silver
    case indigo
    case pink
    case teal
    case amber
    case mint

    public var label: String {
        switch self {
        case .silver: "Silver"
        case .indigo: "Indigo"
        case .pink: "Pink"
        case .teal: "Teal"
        case .amber: "Amber"
        case .mint: "Mint"
        }
    }
}

public enum RefreshFrequency: Int, CaseIterable, Codable, Sendable {
    /// Raw value is the interval in seconds. The slowest picker is 1 minute — Claude's OAuth
    /// usage endpoint rate-limits sub-minute polling (HTTP 429), and the others don't benefit
    /// from faster refresh either since `UsageResetRefreshSchedule` already triggers a fresh
    /// fetch at the moment a limit window rolls over.
    case everyMinute = 60
    case every5Minutes = 300
    case every15Minutes = 900
    case every30Minutes = 1800

    public var label: String {
        switch self {
        case .everyMinute: "Every minute"
        case .every5Minutes: "Every 5 minutes"
        case .every15Minutes: "Every 15 minutes"
        case .every30Minutes: "Every 30 minutes"
        }
    }

    public var interval: TimeInterval {
        TimeInterval(rawValue)
    }
}

public enum MenuBarDisplayMode: String, CaseIterable, Codable, Sendable {
    case sessionNumber
    case sessionAndWeeklyNumbers
    case capacity

    public var label: String {
        switch self {
        case .sessionNumber: "5h Number"
        case .sessionAndWeeklyNumbers: "5h + 1w"
        case .capacity: "Capacity"
        }
    }
}

/// Concrete `Color` value for an `AccentChoice`. Lives here so the framework module does not
/// have to know about SwiftUI's `Color` (and tests can compare raw values without rendering).
public extension AccentChoice {
    /// sRGB triples calibrated against the existing dark canvas so all choices read with
    /// roughly the same luminosity. `silver` is deliberately near-neutral: `Brand` detects
    /// the low saturation and falls back to the original grey ramps. Tweak with care —
    /// changing these is a brand-level change.
    var sRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .silver: (0.75, 0.75, 0.78)
        case .indigo: (0.55, 0.50, 0.95)
        case .pink:   (0.95, 0.42, 0.65)
        case .teal:   (0.27, 0.78, 0.82)
        case .amber:  (0.98, 0.70, 0.28)
        case .mint:   (0.45, 0.88, 0.62)
        }
    }

    /// Saturation of the sRGB triple. `Brand` uses this to detect the neutral silver choice.
    var isNeutral: Bool {
        let c = sRGB
        let maxV = max(c.red, c.green, c.blue)
        let minV = min(c.red, c.green, c.blue)
        return (maxV - minV) < 0.04
    }
}

@MainActor
public enum AppPreferences {
    public static let usageDisplayModeKey = "usageDisplayMode"
    public static let defaultUsageDisplayMode = UsageDisplayMode.remaining
    public static let menuBarDisplayModeKey = "menuBarDisplayMode"
    public static let defaultMenuBarDisplayMode = MenuBarDisplayMode.capacity
    public static let refreshFrequencyKey = "refreshIntervalMinutes"
    public static let defaultRefreshFrequency = RefreshFrequency.every5Minutes
    /// `nonisolated` because they are plain constants, not part of the `UserDefaults`-backed
    /// state the rest of this type guards: `ThemeAccentKey.defaultValue` and `Brand`'s metal
    /// ramps read them from nonisolated contexts.
    nonisolated public static let accentChoiceKey = "accentChoice"
    nonisolated public static let defaultAccentChoice = AccentChoice.silver
    /// JSON-encoded `[ProviderSnapshot]` written by the menu-bar tracker and read by the
    /// control center. The two run as separate processes; this is the only channel that
    /// carries the latest live numbers into the control-center window.
    public static let providerSnapshotsKey = "providerSnapshots"
    /// Wall-clock timestamp the tracker wrote its last snapshot bundle, so the control
    /// center can show "Updated 3m ago" without re-fetching anything.
    public static let providerSnapshotsUpdatedAtKey = "providerSnapshotsUpdatedAt"
    public static let didChangeNotification = Notification.Name("com.llmusage.preferencesDidChange")
    public static let snapshotsDidChangeNotification = Notification.Name("com.llmusage.snapshotsDidChange")
    @MainActor public static let defaults = UserDefaults(suiteName: "com.llmusage.shared")!

    public static var usageDisplayMode: UsageDisplayMode {
        defaults.string(forKey: usageDisplayModeKey).flatMap(UsageDisplayMode.init(rawValue:)) ?? defaultUsageDisplayMode
    }

    public static var refreshFrequency: RefreshFrequency {
        RefreshFrequency(rawValue: defaults.integer(forKey: refreshFrequencyKey)) ?? defaultRefreshFrequency
    }

    public static var menuBarDisplayMode: MenuBarDisplayMode {
        defaults.string(forKey: menuBarDisplayModeKey).flatMap(MenuBarDisplayMode.init(rawValue:)) ?? defaultMenuBarDisplayMode
    }

    public static var accentChoice: AccentChoice {
        defaults.string(forKey: accentChoiceKey).flatMap(AccentChoice.init(rawValue:)) ?? defaultAccentChoice
    }
}

/// Where the menu bar tracker lives. It is a helper, not something the user launches: it sits
/// in Application Support rather than Applications, so only LLMUsage.app ever starts or stops
/// it, and it never turns up in Spotlight, Launchpad, or the Finder alongside the real app.
///
/// It is still an app bundle — a status item needs `LSUIElement` and an `Info.plist`, and
/// stopping it needs a bundle identifier to find the running process by.
public enum TrackerHelper {
    public static let bundleIdentifier = "com.llmusage.tracker"
    public static let bundleName = "LLMUsage_Tracker.app"

    public static var supportDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("LLMUsage", isDirectory: true)
    }

    public static var bundleURL: URL {
        supportDirectory.appendingPathComponent(bundleName, isDirectory: true)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: bundleURL.path)
    }
}

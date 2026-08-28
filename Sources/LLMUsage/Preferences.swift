import AppKit
import Combine
import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// One writable model for every preference the control center exposes. Each setter writes
/// through to the shared defaults suite and pokes the tracker, so the menu bar re-renders
/// while the user is still looking at the picker.
@MainActor
final class Preferences: ObservableObject {
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { write(menuBarDisplayMode.rawValue, AppPreferences.menuBarDisplayModeKey) }
    }

    @Published var usageDisplayMode: UsageDisplayMode {
        didSet { write(usageDisplayMode.rawValue, AppPreferences.usageDisplayModeKey) }
    }

    @Published var refreshFrequency: RefreshFrequency {
        didSet { write(refreshFrequency.rawValue, AppPreferences.refreshFrequencyKey) }
    }

    @Published var accentChoice: AccentChoice {
        didSet { write(accentChoice.rawValue, AppPreferences.accentChoiceKey) }
    }

    init() {
        menuBarDisplayMode = AppPreferences.menuBarDisplayMode
        usageDisplayMode = AppPreferences.usageDisplayMode
        refreshFrequency = AppPreferences.refreshFrequency
        accentChoice = AppPreferences.accentChoice
    }

    private func write(_ value: Any, _ key: String) {
        AppPreferences.defaults.set(value, forKey: key)
        DistributedNotificationCenter.default().post(
            name: AppPreferences.didChangeNotification,
            object: nil
        )
    }
}

/// Live view of the latest snapshot bundle the menu-bar tracker wrote. The control center
/// runs as a separate process; this store is the bridge — it listens for the tracker's
/// "snapshots changed" notification, decodes whatever was just persisted, and republishes it
/// as `@Published` so SwiftUI views render the same numbers without polling.
@MainActor
final class SnapshotStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var updatedAt: Date?

    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: AppPreferences.snapshotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        // SnapshotStore lives for the lifetime of the control-center window; the observer is
        // torn down with the process, so we don't need to do anything here.
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = AppPreferences.defaults.data(forKey: AppPreferences.providerSnapshotsKey),
           let decoded = try? decoder.decode([ProviderSnapshot].self, from: data) {
            snapshots = decoded
        }
        updatedAt = AppPreferences.defaults.object(forKey: AppPreferences.providerSnapshotsUpdatedAtKey) as? Date
    }
}

/// Whether the menu bar tracker process is alive. The tracker is launched from its
/// Application Support location by path — it is deliberately not registered as an app the
/// user could open themselves.
///
/// This polls rather than observing `NSWorkspace`: the workspace launch and terminate
/// notifications are only posted for apps that appear in the Dock, and the tracker is an
/// accessory that never does, so observing them left this switch showing the opposite of
/// what was actually running.
@MainActor
final class TrackerStatus: ObservableObject {
    @Published private(set) var isRunning = false
    /// False when the helper is missing from Application Support, which means a broken or
    /// half-finished install rather than a tracker the user turned off.
    @Published private(set) var isInstalled = TrackerHelper.isInstalled

    private static let pollInterval: TimeInterval = 1
    /// How long the poll defers to a flip the user just made. `terminate()` is asynchronous,
    /// so a poll landing immediately after would still see the old process and bounce the
    /// switch back under the user's finger.
    private static let settlingPeriod: TimeInterval = 2

    private var pollTask: Task<Void, Never>?
    private var settledAfter: Date = .distantPast

    init() {
        reconcile()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                self?.poll()
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    /// Re-reads the world, ignoring anything the user did in the last moment.
    func refresh() {
        settledAfter = .distantPast
        reconcile()
    }

    func start() {
        guard TrackerHelper.isInstalled else {
            refresh()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // The tracker has no windows; pulling focus away from this one would be pure noise.
        configuration.activates = false
        hold()
        NSWorkspace.shared.openApplication(at: TrackerHelper.bundleURL,
                                           configuration: configuration) { application, _ in
            Task { @MainActor in
                // The launch result is authoritative sooner than the process list is.
                self.hold()
                self.apply(isRunning: application != nil)
            }
        }
    }

    func stop() {
        hold()
        runningInstances.forEach { _ = $0.terminate() }
        apply(isRunning: false)
    }

    private func poll() {
        guard Date() >= settledAfter else { return }
        reconcile()
    }

    private func reconcile() {
        apply(isRunning: !runningInstances.isEmpty, isInstalled: TrackerHelper.isInstalled)
    }

    private func hold() {
        settledAfter = Date().addingTimeInterval(Self.settlingPeriod)
    }

    private func apply(isRunning running: Bool, isInstalled installed: Bool? = nil) {
        let resolvedInstalled = installed ?? isInstalled
        guard running != isRunning || resolvedInstalled != isInstalled else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            isRunning = running
            isInstalled = resolvedInstalled
        }
    }

    private var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: TrackerHelper.bundleIdentifier
        )
    }
}

/// Stand-in numbers for the live previews. Realistic and deliberately uneven, so every
/// preview shows what a real strip looks like rather than three identical bars.
enum SampleUsage {
    struct Provider {
        let id: String
        let displayName: String
        let sessionUsed: Int
        let weeklyUsed: Int
    }

    static let providers = [
        Provider(id: "claude", displayName: "Claude", sessionUsed: 34, weeklyUsed: 58),
        Provider(id: "codex", displayName: "Codex", sessionUsed: 12, weeklyUsed: 41),
        Provider(id: "zai", displayName: "GLM", sessionUsed: 78, weeklyUsed: 66),
        Provider(id: "minimax", displayName: "MiniMax", sessionUsed: 21, weeklyUsed: 47)
    ]

    static func metrics(displayMode: UsageDisplayMode) -> [StatusMetric] {
        providers.map { provider in
            StatusMetric(
                id: provider.id,
                displayName: provider.displayName,
                value: "\(displayMode.displayPercent(forUsed: provider.sessionUsed))%",
                secondaryValue: "\(displayMode.displayPercent(forUsed: provider.weeklyUsed))%",
                percent: displayMode.displayPercent(forUsed: provider.sessionUsed)
            )
        }
    }
}

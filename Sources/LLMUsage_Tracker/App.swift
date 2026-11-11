import AppKit
import Darwin
import Foundation
import LLMUsagePreferences
import LLMUsageHistory
import LLMUsageRemote
import LLMUsageUI
import SwiftUI

@main
struct LLMUsageTrackerApp {
    @MainActor
    static func main() async {
        let configuration = RuntimeConfiguration.current
        let providers: [any UsageProvider] = configuration.role == .server
            ? [ClaudeProvider(), CodexProvider(), ZAIProvider(), MiniMaxProvider()] : []
        if CommandLine.arguments.contains("--once") {
            if configuration.role == .client {
                do {
                    let document = try await RemoteUsageClient(configuration: configuration).quota()
                    AppDelegate.printOnce(document.snapshots)
                } catch {
                    FileHandle.standardError.write(Data("LLMUsage: \(error.localizedDescription)\n".utf8))
                    exit(EXIT_FAILURE)
                }
                return
            }
            let active = providers.filter { !AppPreferences.disabledProviderIDs.contains($0.id) }
            let results = await AppDelegate.fetchAll(active)
            AppDelegate.printOnce(results, providers: active)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(providers: providers, configuration: configuration)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let providers: [any UsageProvider]
    private var snapshots: [String: ProviderSnapshot] = [:]
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostingController: NSHostingController<UsageDashboardView>?
    private var refreshTimer: Timer?
    private var resetRefreshTimer: Timer?
    private var isRefreshing = false
    private var preferencesObserver: NSObjectProtocol?
    private let configuration: RuntimeConfiguration
    private let remote: RemoteUsageClient
    private let warmUp: WarmUpCoordinator?
    private var historyTask: Task<Void, Never>?
    private var lastHistoryRefresh: Date = .distantPast
    private let launchAtLogin: TrackerLoginItem?

    init(providers: [any UsageProvider], configuration: RuntimeConfiguration = .current) {
        self.providers = providers
        self.configuration = configuration
        remote = RemoteUsageClient(configuration: configuration)
        warmUp = configuration.role == .server
            ? WarmUpCoordinator(window: Self.sessionWindow(providers)) : nil
        launchAtLogin = Bundle.main.bundleIdentifier == TrackerHelper.bundleIdentifier
            ? TrackerLoginItem() : nil
    }

    /// Accounts the tracker actually polls. Read per use rather than cached at launch so a
    /// flip in the control center takes effect on the next refresh — and immediately, via
    /// `handlePreferencesChange`.
    private var activeProviders: [any UsageProvider] {
        providers.filter { !AppPreferences.disabledProviderIDs.contains($0.id) }
    }

    private var displayedProviders: [(id: String, displayName: String)] {
        if configuration.role == .server {
            return activeProviders.map { ($0.id, $0.displayName) }
        }
        return snapshots.values.sorted { $0.id < $1.id }.map { ($0.id, $0.displayName) }
    }

    /// Warm up asks for the client's session window at the instant it fires; the published
    /// snapshot can be a whole refresh interval old, and a window opened in that gap would
    /// turn the warm up into a plain request that spends quota for nothing.
    private static func sessionWindow(_ providers: [any UsageProvider]) -> WarmUpCoordinator.Window {
        { client in
            guard let provider = providers.first(where: { $0.id == client.providerID }),
                  let usage = try? await provider.fetchUsage() else { return nil }
            return Self.openSessionEnd(in: usage)
        }
    }

    /// A future reset is only an open window when the provider also reports activity. Codex
    /// publishes a moving `now + 5 hours` reset while usage is still zero; treating that as
    /// active suppresses the request that should establish the real window.
    nonisolated static func openSessionEnd(in usage: Usage) -> Date? {
        guard let session = usage.lines.first(where: { $0.label == "Session" }),
              session.windowIsActive != false else { return nil }
        return session.resetsAt
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchAtLogin?.start()
        configureMainMenu()
        configureStatusItem()
        configurePopover()
        scheduleRefreshTimer()
        warmUp?.start()
        if configuration.role == .client {
            let cached = remote.cachedQuota()
            let results = cached?.snapshots ?? []
            snapshots = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            publishSnapshots(results, at: cached?.updatedAt)
            updatePresentation()
        }
        preferencesObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePreferencesChange() }
        }
        Task { await refresh() }
    }

    /// Persist the latest snapshot bundle to the shared defaults suite so the control center
    /// (a separate process) can show the same numbers without re-fetching from each provider.
    private func publishSnapshots(_ snapshots: [ProviderSnapshot], at updatedAt: Date? = Date()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        AppPreferences.defaults.set(data, forKey: AppPreferences.providerSnapshotsKey)
        AppPreferences.defaults.set(updatedAt, forKey: AppPreferences.providerSnapshotsUpdatedAtKey)
        if configuration.role == .server { try? UsageExport.write(snapshots) }
        DistributedNotificationCenter.default().post(
            name: AppPreferences.snapshotsDidChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchAtLogin?.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        resetRefreshTimer?.invalidate()
        resetRefreshTimer = nil
        warmUp?.stop()
        historyTask?.cancel()
        if let preferencesObserver {
            DistributedNotificationCenter.default().removeObserver(preferencesObserver)
        }
        preferencesObserver = nil
        popover.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "LLMUsage")
        button.image?.isTemplate = true
        button.setAccessibilityLabel("LLMUsage, loading usage")
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "LLMUsage")
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "LLMUsage")

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit LLMUsage",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(quitItem)

        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        // The panel paints its own dark canvas; without this the popover's chrome and arrow
        // would follow the system appearance and frame it in a light border.
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        updatePresentation()
        if configuration.role == .client {
            do {
                let document = try await remote.quota()
                let results = document.snapshots
                snapshots = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
                AppPreferences.defaults.removeObject(forKey: AppPreferences.serverConnectionErrorKey)
                publishSnapshots(results, at: document.updatedAt)
                statusItem?.button?.toolTip = configuration.serverName ?? "Server"
            } catch {
                AppPreferences.defaults.set(error.localizedDescription, forKey: AppPreferences.serverConnectionErrorKey)
                statusItem?.button?.toolTip = "Offline: \(error.localizedDescription)"
                publishSnapshots(Array(snapshots.values), at: remote.cachedQuota()?.updatedAt)
            }
            isRefreshing = false
            updatePresentation()
            return
        }
        // Rebuilding the dictionary wholesale drops the snapshot of an account switched off
        // mid-flight instead of letting it linger until the next relaunch.
        let results = await Self.fetchAll(activeProviders)
        snapshots = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        publishSnapshots(results)
        refreshHistoryIfNeeded()
        isRefreshing = false
        scheduleResetRefreshTimer()
        updatePresentation()
        // A refresh that raced an account being switched back on misses it; pick it up now
        // rather than at the next periodic tick. `fetchAll` returns a snapshot for every
        // provider, success or failure, so this cannot loop.
        if activeProviders.contains(where: { snapshots[$0.id] == nil }) {
            await refresh()
        }
    }

    private func refreshHistoryIfNeeded() {
        guard historyTask == nil, Date().timeIntervalSince(lastHistoryRefresh) >= 300 else { return }
        historyTask = Task { [weak self] in
            let repository = UsageHistoryRepository()
            let snapshot = await repository.refresh(daysBack: 90)
            guard !Task.isCancelled else { return }
            do {
                try UsageHistoryExport.write(snapshot)
                self?.lastHistoryRefresh = Date()
            } catch {
                NSLog("History export failed: %@", error.localizedDescription)
            }
            self?.historyTask = nil
        }
    }

    /// Reacts to a preference flip from the control center. The refresh cadence may have
    /// changed, and an account just switched off has to leave the strip now, not at the next
    /// refresh. A switched-on account has no snapshot yet, so it needs a full fetch.
    private func handlePreferencesChange() {
        scheduleRefreshTimer()
        guard configuration.role == .server else {
            updatePresentation()
            return
        }
        let active = activeProviders
        let activeIDs = Set(active.map(\.id))
        let before = snapshots
        snapshots = before.filter { activeIDs.contains($0.key) }
        if snapshots.count != before.count {
            publishSnapshots(active.compactMap { snapshots[$0.id] })
            scheduleResetRefreshTimer()
        }
        updatePresentation()
        if active.contains(where: { snapshots[$0.id] == nil }) {
            refreshNow()
        }
    }

    private func updatePresentation() {
        if let hostingController {
            hostingController.rootView = dashboardView()
            // The panel's height follows how many quota lines came back, so the popover has
            // to be re-sized whenever the content changes rather than only when it opens.
            popover.contentSize = hostingController.sizeThatFits(
                in: NSSize(width: UsageDashboardView.width, height: UsageDashboardView.maxHeight)
            )
        }
        updateStatusItem()
    }

    private func dashboardView() -> UsageDashboardView {
        UsageDashboardView(
            providers: displayedProviders.map {
                ProviderCardState(id: $0.id, displayName: $0.displayName, snapshot: snapshots[$0.id])
            },
            displayMode: AppPreferences.usageDisplayMode,
            isRefreshing: isRefreshing,
            connectionError: configuration.role == .client
                ? AppPreferences.defaults.string(forKey: AppPreferences.serverConnectionErrorKey) : nil,
            onRefresh: { [weak self] in self?.refreshNow() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let displayMode = AppPreferences.usageDisplayMode
        let menuBarDisplayMode = AppPreferences.menuBarDisplayMode
        let metrics = displayedProviders.map { provider in
            let presentation = Self.compactPresentation(
                for: snapshots[provider.id],
                displayMode: displayMode
            )
            return StatusMetric(
                id: provider.id,
                displayName: provider.displayName,
                value: presentation.value,
                secondaryValue: presentation.secondaryValue,
                percent: presentation.percent,
                sessionBlockedByWeeklyLimit: presentation.sessionBlockedByWeeklyLimit
            )
        }
        let colorScheme: ColorScheme = button.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua ? .dark : .light
        // Every account switched off: there is no strip to draw, so the item wears the plain
        // gauge it had before the first snapshot instead of a blank or stale strip.
        guard !metrics.isEmpty else {
            if let image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "LLMUsage") {
                button.image = image
                button.image?.isTemplate = true
                statusItem?.length = NSStatusItem.variableLength
            }
            button.setAccessibilityLabel("LLMUsage")
            return
        }
        if let image = StatusStripRenderer.image(
            metrics: metrics,
            displayMode: menuBarDisplayMode,
            colorScheme: colorScheme
        ) {
            button.image = image
            button.imagePosition = .imageOnly
            statusItem?.length = image.size.width + 4
        }
        button.setAccessibilityLabel(metrics.map(\.accessibilitySummary).joined(separator: ", "))
    }

    nonisolated static func compactPresentation(
        for snapshot: ProviderSnapshot?,
        displayMode: UsageDisplayMode
    ) -> (
        value: String,
        secondaryValue: String?,
        percent: Int?,
        sessionBlockedByWeeklyLimit: Bool
    ) {
        guard let snapshot else { return ("…", nil, nil, false) }
        switch snapshot.result {
        case .success(let usage):
            let sessionUsedPercent = usage.lines.first(where: { $0.label == "Session" })?.percent
                ?? usage.lines.compactMap(\.percent).first
            guard let sessionUsedPercent else { return ("—", nil, nil, false) }
            let weeklyUsedPercent = usage.lines.first(where: { $0.label == "Weekly" })?.percent
            let sessionDisplayPercent = displayMode.displayPercent(forUsed: sessionUsedPercent)
            let weeklyDisplayPercent = weeklyUsedPercent.map(displayMode.displayPercent(forUsed:))
            // The capacity bar takes its fill from the same perspective as the numbers:
            // Glass Half Full drains, Glass Half Empty fills.
            let filledPercent = displayMode.displayPercent(forUsed: sessionUsedPercent)
            let sessionBlockedByWeeklyLimit = QuotaRelationship.sessionIsBlockedByWeeklyLimit(
                sessionUsedPercent: sessionUsedPercent,
                weeklyUsedPercent: weeklyUsedPercent
            )
            return (
                "\(sessionDisplayPercent)%",
                weeklyDisplayPercent.map { "\($0)%" },
                filledPercent,
                sessionBlockedByWeeklyLimit
            )
        case .emptyButSuccessful:
            return ("⚠", nil, nil, false)
        case .missingCredentials:
            return ("—", nil, nil, false)
        case .rateLimited, .authExpired, .noPlan, .network:
            return ("!", nil, nil, false)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let controller = NSHostingController(rootView: dashboardView())
            hostingController = controller
            popover.contentViewController = controller
            popover.contentSize = controller.sizeThatFits(
                in: NSSize(width: UsageDashboardView.width, height: UsageDashboardView.maxHeight)
            )
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refreshNow() {
        Task { await refresh() }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: AppPreferences.refreshFrequency.interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func scheduleResetRefreshTimer(now: Date = .now) {
        resetRefreshTimer?.invalidate()
        resetRefreshTimer = nil

        guard let refreshDate = UsageResetRefreshSchedule.nextRefreshDate(
            for: Array(snapshots.values),
            now: now
        ) else { return }

        let timer = Timer(timeInterval: refreshDate.timeIntervalSince(now), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetRefreshTimer = nil
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetRefreshTimer = timer
    }

    @objc private func openSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.llmusage.app") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    nonisolated static func fetchAll(_ providers: [any UsageProvider]) async -> [ProviderSnapshot] {
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return ProviderSnapshot(
                            id: provider.id,
                            displayName: provider.displayName,
                            result: .success(try await provider.fetchUsage())
                        )
                    } catch let error as UsageError {
                        return ProviderSnapshot(id: provider.id, displayName: provider.displayName, result: SnapshotResult(.failure(error)))
                    } catch {
                        return ProviderSnapshot(
                            id: provider.id,
                            displayName: provider.displayName,
                            result: .network(error.localizedDescription)
                        )
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    nonisolated static func printOnce(_ snapshots: [ProviderSnapshot], providers: [any UsageProvider]? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for id in providers?.map(\.id) ?? snapshots.map(\.id) {
            guard let snapshot = byID[id] else { continue }
            switch snapshot.result {
            case .success(let usage):
                let plan = usage.plan.map { " [\($0)]" } ?? ""
                let details = usage.lines.map { line in
                    if let percent = line.percent { return "\(line.label)=\(percent)%" }
                    return "\(line.label)=\(line.text ?? "—")"
                }.joined(separator: ", ")
                print("\(snapshot.displayName)\(plan): \(details)")
            case .missingCredentials:
                print("\(snapshot.displayName): ERROR Missing credentials")
            case .authExpired:
                print("\(snapshot.displayName): ERROR Authentication expired")
            case .network(let text):
                print("\(snapshot.displayName): ERROR \(text)")
            case .noPlan:
                print("\(snapshot.displayName): ERROR No active plan")
            case .rateLimited(let retry):
                print("\(snapshot.displayName): ERROR Rate limited\(retry.map { " (retry in \($0)s)" } ?? "")")
            case .emptyButSuccessful:
                print("\(snapshot.displayName): ERROR Empty successful response")
            }
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// A closed popover keeps its window, so a hosting view left in it keeps SwiftUI's
    /// repeating background animation rendering off screen.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        hostingController = nil
    }
}

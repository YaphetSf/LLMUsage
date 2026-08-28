import AppKit
import Foundation
import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

@main
struct LLMUsageTrackerApp {
    @MainActor
    static func main() async {
        let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), ZAIProvider(), MiniMaxProvider()]
        if CommandLine.arguments.contains("--once") {
            let results = await AppDelegate.fetchAll(providers)
            AppDelegate.printOnce(results, providers: providers)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(providers: providers)
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

    init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        configurePopover()
        scheduleRefreshTimer()
        preferencesObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefreshTimer()
                self?.updatePresentation()
            }
        }
        Task { await refresh() }
    }

    /// Persist the latest snapshot bundle to the shared defaults suite so the control center
    /// (a separate process) can show the same numbers without re-fetching from each provider.
    private func publishSnapshots(_ snapshots: [ProviderSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshots) else { return }
        AppPreferences.defaults.set(data, forKey: AppPreferences.providerSnapshotsKey)
        AppPreferences.defaults.set(Date(), forKey: AppPreferences.providerSnapshotsUpdatedAtKey)
        DistributedNotificationCenter.default().post(
            name: AppPreferences.snapshotsDidChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        resetRefreshTimer?.invalidate()
        resetRefreshTimer = nil
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
        let results = await Self.fetchAll(providers)
        snapshots = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        publishSnapshots(results)
        isRefreshing = false
        scheduleResetRefreshTimer()
        updatePresentation()
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
            providers: providers.map {
                ProviderCardState(id: $0.id, displayName: $0.displayName, snapshot: snapshots[$0.id])
            },
            displayMode: AppPreferences.usageDisplayMode,
            isRefreshing: isRefreshing,
            onRefresh: { [weak self] in self?.refreshNow() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let displayMode = AppPreferences.usageDisplayMode
        let menuBarDisplayMode = AppPreferences.menuBarDisplayMode
        let metrics = providers.map { provider in
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

    nonisolated static func printOnce(_ snapshots: [ProviderSnapshot], providers: [any UsageProvider]) {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for provider in providers {
            guard let snapshot = byID[provider.id] else { continue }
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

import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

private struct LoginItemState: Codable {
    let status: Int
    let error: String?
}

@MainActor
public final class TrackerLoginItem {
    private let defaults: UserDefaults
    private let service: any LoginItemService
    private let notifications: NotificationCenter
    private var observers: Set<AnyCancellable> = []
    private var lastError: String?

    public convenience init() {
        self.init(
            defaults: AppPreferences.defaults,
            service: SMAppService.mainApp,
            notifications: DistributedNotificationCenter.default()
        )
    }

    init(defaults: UserDefaults, service: any LoginItemService, notifications: NotificationCenter) {
        self.defaults = defaults
        self.service = service
        self.notifications = notifications
    }

    public func start() {
        guard observers.isEmpty else { return }
        notifications.publisher(for: AppPreferences.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &observers)
        notifications.publisher(for: LaunchAtLoginController.statusRequestedNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &observers)
        reconcile()
    }

    public func stop() {
        observers.removeAll()
    }

    private var wantsEnabled: Bool {
        defaults.object(forKey: LaunchAtLoginController.preferenceKey) as? Bool ?? true
    }

    public func reconcile() {
        lastError = nil
        do {
            switch (wantsEnabled, service.status) {
            case (true, .notRegistered), (true, .notFound):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            default:
                break
            }
        } catch {
            if !matchesIntent(service.status) {
                lastError = error.localizedDescription
            }
        }
        if lastError == nil && !matchesIntent(service.status) {
            lastError = wantsEnabled
                ? "The tracker login item is not registered."
                : "The tracker login item is still registered."
        }
        publishState()
    }

    private func refresh() {
        if matchesIntent(service.status) { lastError = nil }
        publishState()
    }

    private func matchesIntent(_ status: SMAppService.Status) -> Bool {
        if wantsEnabled {
            return status == .enabled || status == .requiresApproval
        }
        return status == .notRegistered || status == .notFound
    }

    private func publishState() {
        let state = LoginItemState(status: service.status.rawValue, error: lastError)
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: LaunchAtLoginController.stateKey)
        notifications.post(name: LaunchAtLoginController.stateDidChangeNotification, object: nil)
    }
}

@MainActor
public final class LaunchAtLoginController: ObservableObject {
    static let preferenceKey = "launchAtLoginEnabled"
    static let stateKey = "launchAtLoginState"
    static let statusRequestedNotification = Notification.Name("com.llmusage.loginItemStatusRequested")
    static let stateDidChangeNotification = Notification.Name("com.llmusage.loginItemStateDidChange")

    @Published public private(set) var status: SMAppService.Status = .notRegistered
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private var observer: AnyCancellable?

    public convenience init() {
        self.init(defaults: AppPreferences.defaults, notifications: DistributedNotificationCenter.default())
    }

    init(defaults: UserDefaults, notifications: NotificationCenter) {
        self.defaults = defaults
        self.notifications = notifications
        observer = notifications.publisher(for: Self.stateDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.loadState() }
            }
        refresh()
    }

    public var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    public var requiresUserApproval: Bool {
        status == .requiresApproval
    }

    public func refresh() {
        loadState()
        notifications.post(name: Self.statusRequestedNotification, object: nil)
    }

    public func setEnabled(_ enabled: Bool) {
        // Persist intent before asking the tracker, including when registration fails.
        defaults.set(enabled, forKey: Self.preferenceKey)
        lastError = nil
        notifications.post(name: AppPreferences.didChangeNotification, object: nil)
    }

    private func loadState() {
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(LoginItemState.self, from: data) else { return }
        status = SMAppService.Status(rawValue: state.status) ?? .notRegistered
        lastError = state.error
    }

    public func clearError() {
        lastError = nil
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

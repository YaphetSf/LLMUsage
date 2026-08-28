import Foundation
import Combine
import ServiceManagement

/// Owns the toggle that opens LLMUsage's menu-bar tracker at login.
///
/// The tracker is a separate `.app` bundle living in Application Support, so it cannot use
/// `SMAppService.mainApp` to register itself — that API only works for the calling app and
/// requires the bundle to live in a LaunchServices-known location like `/Applications`. The
/// control center instead registers a `LaunchAgent` plist (bundled in the control center's
/// own `.app` at `Contents/Library/LaunchAgents/`) that points at the tracker's executable
/// by path. `SMAppService.agent(plistName:)` is the macOS-blessed API for that pattern.
///
/// Both processes observe `AppPreferences.defaults` for the persisted state and a
/// DistributedNotification for change pings, so flipping the switch in the control center
/// reaches the tracker (and vice versa) without any bespoke IPC.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    /// Matches the plist shipped inside `LLMUsage.app/Contents/Library/LaunchAgents/`.
    public static let agentPlistName = "com.llmusage.tracker.plist"

    /// What `SMAppService` reports right now. `requiresApproval` means the user has flipped
    /// the switch but hasn't yet allowed the helper in *System Settings → General → Login
    /// Items* — the toggle should reflect that without lying about whether registration
    /// succeeded.
    @Published public private(set) var status: SMAppService.Status = .notRegistered
    @Published public private(set) var lastError: String?

    private var observer: NSObjectProtocol?

    public init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: AppPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // The observer lives for the lifetime of the control-center window; tearing it down here
    // is the same job Swift will do when the whole process exits, so we leave it alone to
    // avoid touching a non-Sendable Foundation observer from a nonisolated deinit.

    public var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        @unknown default: false
        }
    }

    public var requiresUserApproval: Bool {
        status == .requiresApproval
    }

    public func refresh() {
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        status = service.status
    }

    /// Flips the toggle to match the desired state. Returns `true` if `SMAppService` accepted
    /// the change. A `false` return with `requiresApproval == true` is success-on-paper: the
    /// user just hasn't confirmed in System Settings yet, so the UI should keep the toggle
    /// on and show the "Allow in Login Items" hint.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            if enabled {
                if service.status == .enabled { return true }
                try service.register()
            } else {
                if service.status == .notRegistered { return true }
                try service.unregister()
            }
            lastError = nil
            status = service.status
            DistributedNotificationCenter.default().post(
                name: AppPreferences.didChangeNotification,
                object: nil
            )
            return true
        } catch {
            lastError = error.localizedDescription
            status = service.status
            return false
        }
    }
}

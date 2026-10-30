import Foundation
import ServiceManagement
import Testing
@testable import LLMUsagePreferences

@MainActor
private final class LoginItemStub: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var statusAfterRegistrationError: SMAppService.Status?
    var unregistrationError: Error?
    var registerCount = 0
    var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let registrationError {
            if let statusAfterRegistrationError { status = statusAfterRegistrationError }
            throw registrationError
        }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}

@MainActor
private struct LoginItemFixture {
    let suiteName = "com.llmusage.tests.login.\(UUID().uuidString)"
    let defaults: UserDefaults
    let notifications = NotificationCenter()
    let service = LoginItemStub()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func tracker() -> TrackerLoginItem {
        TrackerLoginItem(defaults: defaults, service: service, notifications: notifications)
    }

    func controlCenter() -> LaunchAtLoginController {
        LaunchAtLoginController(defaults: defaults, notifications: notifications)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
struct LaunchAtLoginTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test func trackerLaunchRegistersWithoutOpeningTheControlCenter() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }

        #expect(fixture.service.registerCount == 1)
        #expect(fixture.service.status == .enabled)
        #expect(fixture.defaults.object(forKey: LaunchAtLoginController.preferenceKey) == nil)

        let controlCenter = fixture.controlCenter()
        #expect(controlCenter.isEnabled)
        #expect(controlCenter.lastError == nil)
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func lostRegistrationIsRepairedOnTheNextTrackerLaunch(status: SMAppService.Status) {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: LaunchAtLoginController.preferenceKey)
        let tracker = fixture.tracker()
        tracker.start()
        tracker.stop()
        fixture.service.status = status

        let relaunched = fixture.tracker()
        relaunched.start()
        defer { relaunched.stop() }
        #expect(fixture.service.registerCount == 2)
        #expect(fixture.service.status == .enabled)
        #expect(fixture.controlCenter().isEnabled)
    }

    @Test func explicitOffUsesTheTrackerServiceAndSurvivesRelaunch() async throws {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        let tracker = fixture.tracker()
        tracker.start()
        let controlCenter = fixture.controlCenter()
        controlCenter.setEnabled(false)
        #expect(fixture.defaults.object(forKey: LaunchAtLoginController.preferenceKey) as? Bool == false)
        try await waitFor { fixture.service.unregisterCount == 1 && !controlCenter.isEnabled }
        tracker.stop()

        let relaunched = fixture.tracker()
        relaunched.start()
        defer { relaunched.stop() }
        #expect(fixture.service.registerCount == 1)
        #expect(fixture.service.unregisterCount == 1)
        #expect(!fixture.controlCenter().isEnabled)
    }

    @Test func offSetWhileTheTrackerIsStoppedIsAppliedAtStartup() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.service.status = .enabled
        fixture.controlCenter().setEnabled(false)
        #expect(fixture.service.unregisterCount == 0)

        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        #expect(fixture.service.unregisterCount == 1)
        #expect(fixture.service.registerCount == 0)
        #expect(!fixture.controlCenter().isEnabled)
    }

    @Test func offBeforeFirstTrackerLaunchNeverRegisters() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.controlCenter().setEnabled(false)
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        #expect(fixture.service.registerCount == 0)
        #expect(fixture.service.unregisterCount == 0)
        #expect(!fixture.controlCenter().isEnabled)
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func existingRegistrationIsNotRepeated(status: SMAppService.Status) {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.service.status = status
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        tracker.reconcile()
        let controlCenter = fixture.controlCenter()
        #expect(fixture.service.registerCount == 0)
        #expect(controlCenter.status == status)
        #expect(controlCenter.isEnabled)
        #expect(controlCenter.requiresUserApproval == (status == .requiresApproval))
    }

    @Test func pendingApprovalIsLeftForTheUserAcrossLaunches() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.service.registrationStatus = .requiresApproval
        let tracker = fixture.tracker()
        tracker.start()
        tracker.stop()

        let relaunched = fixture.tracker()
        relaunched.start()
        defer { relaunched.stop() }
        let controlCenter = fixture.controlCenter()
        #expect(fixture.service.registerCount == 1)
        #expect(controlCenter.requiresUserApproval)
        #expect(controlCenter.lastError == nil)
    }

    @Test func refreshShowsTheSameServiceWithoutChangingRegistration() async throws {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        let controlCenter = fixture.controlCenter()
        fixture.service.status = .requiresApproval
        controlCenter.refresh()
        try await waitFor { controlCenter.requiresUserApproval }

        fixture.service.status = .notRegistered
        controlCenter.refresh()
        try await waitFor { !controlCenter.isEnabled }
        #expect(fixture.service.registerCount == 1)
    }

    @Test func failedRegistrationPreservesIntentAndRetriesOnLaunch() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.controlCenter().setEnabled(true)
        fixture.service.registrationError = NSError(domain: "LoginItemTests", code: 1)
        let tracker = fixture.tracker()
        tracker.start()
        tracker.stop()
        let controlCenter = fixture.controlCenter()
        #expect(!controlCenter.isEnabled)
        #expect(controlCenter.lastError != nil)
        #expect(fixture.defaults.object(forKey: LaunchAtLoginController.preferenceKey) as? Bool == true)

        fixture.service.registrationError = nil
        let relaunched = fixture.tracker()
        relaunched.start()
        defer { relaunched.stop() }
        let refreshed = fixture.controlCenter()
        #expect(refreshed.isEnabled)
        #expect(refreshed.lastError == nil)
        #expect(fixture.service.registerCount == 2)
    }

    @Test func failedUnregisterPreservesOffIntentAndRetriesOnLaunch() async throws {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        let tracker = fixture.tracker()
        tracker.start()
        let controlCenter = fixture.controlCenter()
        fixture.service.unregistrationError = NSError(domain: "LoginItemTests", code: 2)
        controlCenter.setEnabled(false)
        try await waitFor { controlCenter.lastError != nil }
        #expect(controlCenter.isEnabled)
        #expect(fixture.defaults.object(forKey: LaunchAtLoginController.preferenceKey) as? Bool == false)
        tracker.stop()

        fixture.service.unregistrationError = nil
        let relaunched = fixture.tracker()
        relaunched.start()
        defer { relaunched.stop() }
        #expect(fixture.service.registerCount == 1)
        #expect(!fixture.controlCenter().isEnabled)
    }

    @Test func deniedRegistrationWithPendingApprovalShowsTheHint() {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.service.registrationError = NSError(domain: "LoginItemTests", code: kSMErrorLaunchDeniedByUser)
        fixture.service.statusAfterRegistrationError = .requiresApproval
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        let controlCenter = fixture.controlCenter()
        #expect(controlCenter.requiresUserApproval)
        #expect(controlCenter.lastError == nil)
        #expect(fixture.service.registerCount == 1)
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func unconfirmedRegistrationIsNotReportedAsEnabled(status: SMAppService.Status) {
        let fixture = LoginItemFixture()
        defer { fixture.cleanUp() }
        fixture.service.registrationStatus = status
        let tracker = fixture.tracker()
        tracker.start()
        defer { tracker.stop() }
        let controlCenter = fixture.controlCenter()
        #expect(!controlCenter.isEnabled)
        #expect(controlCenter.status == status)
        #expect(controlCenter.lastError != nil)
    }
}

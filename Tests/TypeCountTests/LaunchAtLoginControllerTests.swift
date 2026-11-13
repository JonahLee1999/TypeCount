import Foundation
import ServiceManagement
import Testing
@testable import TypeCount

@MainActor
private final class FakeLoginItemService: LaunchAtLoginService {
    var status: SMAppService.Status
    var registrationError: Error?
    var unregistrationError: Error?
    var statusAfterRegistration: SMAppService.Status = .enabled
    var registrationCalls = 0
    var unregistrationCalls = 0
    var settingsCalls = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registrationCalls += 1
        if let registrationError { throw registrationError }
        status = statusAfterRegistration
    }

    func unregister() async throws {
        unregistrationCalls += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func openSystemSettings() { settingsCalls += 1 }
}

@MainActor
struct LaunchAtLoginControllerTests {
    @Test func initializationAndRefreshOnlyReadActualStatus() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)
        #expect(!controller.enabled)
        #expect(!controller.needsApproval)
        service.status = .enabled
        controller.refresh()
        #expect(controller.enabled)
        #expect(controller.isRegistered)
        #expect(service.registrationCalls == 0)
        #expect(service.unregistrationCalls == 0)
        #expect(service.settingsCalls == 0)
    }

    @Test func waitingForApprovalDoesNotClaimLaunchIsEnabled() async {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegistration = .requiresApproval
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(true)
        #expect(!controller.enabled)
        #expect(controller.needsApproval)
        #expect(controller.isRegistered)
        #expect(controller.status == .requiresApproval)
        #expect(controller.errorMessage == nil)
        #expect(!controller.isUpdating)
        #expect(service.registrationCalls == 1)
        #expect(service.settingsCalls == 0)
        // A pending registration can be cancelled using the same toggle.
        await controller.setEnabled(false)
        #expect(!controller.isRegistered)
        #expect(service.unregistrationCalls == 1)
    }

    @Test func registrationFailureRestoresSystemStateAndExplainsSignature() async {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registrationError = NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorInvalidSignature))
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(true)
        #expect(!controller.enabled)
        #expect(!controller.isRegistered)
        #expect(!controller.isUpdating)
        #expect(controller.errorMessage?.contains("签名") == true)
        #expect(service.registrationCalls == 1)
    }

    @Test func unregistrationFailureKeepsRealEnabledState() async {
        let service = FakeLoginItemService(status: .enabled)
        service.unregistrationError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂时不可用"])
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(false)
        #expect(controller.enabled)
        #expect(!controller.isUpdating)
        #expect(controller.errorMessage?.contains("暂时不可用") == true)
    }

    @Test func unavailableStatusIsVisibleAndSettingsRequireExplicitAction() {
        let service = FakeLoginItemService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)
        #expect(!controller.enabled)
        #expect(!controller.isRegistered)
        #expect(controller.statusDescription.contains("找不到"))
        #expect(service.settingsCalls == 0)
        controller.openSystemSettings()
        #expect(service.settingsCalls == 1)
    }

    @Test func existingRegistrationsAreNotRepeatedAndExternalChangesRefresh() async {
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(true)
        #expect(service.registrationCalls == 0)
        #expect(controller.needsApproval)
        service.status = .enabled
        controller.refresh()
        #expect(controller.enabled)
        #expect(!controller.needsApproval)
        service.status = .notRegistered
        controller.refresh()
        #expect(!controller.enabled)
        #expect(!controller.isRegistered)
    }
}

import Foundation
import Testing
@testable import TypeCount

@MainActor
struct PermissionFlowTests {
    @Test func repeatedAccessibilityRequestAlwaysOpensItsOwnSettings() {
        let store = StatisticsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var opened: [SystemPermission] = []
        var prompts = 0
        let access = PermissionAccess(
            inputAllowed: { false }, accessibilityAllowed: { false },
            requestInput: {}, requestAccessibility: { prompts += 1 },
            openSettings: { opened.append($0) }
        )
        let monitor = InputMonitor(store: store, permissions: access)
        monitor.requestAccessibilityPermission()
        monitor.requestAccessibilityPermission()
        #expect(prompts == 2)
        #expect(opened.count == 2)
        #expect(opened.allSatisfy { $0 == .accessibility })
        #expect(!store.accessibilityPermissionGranted)
        monitor.stop()
    }

    @Test func permissionsRefreshIndependentlyIncludingRevocation() {
        let store = StatisticsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var input = false
        var accessibility = true
        let monitor = InputMonitor(store: store, permissions: PermissionAccess(
            inputAllowed: { input }, accessibilityAllowed: { accessibility },
            requestInput: {}, requestAccessibility: {}, openSettings: { _ in }
        ))
        monitor.refreshPermissions()
        #expect(store.accessibilityPermissionGranted)
        #expect(!store.inputPermissionGranted)
        // Checking an AX grant must not claim that a keyboard tap exists. This
        // monitor has not been started and has created no OS listener.
        #expect(!store.keyboardMonitoringAvailable)
        input = true
        accessibility = false
        monitor.refreshPermissions()
        #expect(!store.accessibilityPermissionGranted)
        #expect(store.inputPermissionGranted)
        monitor.stop()
    }

    @Test func inputRequestCannotNavigateToAccessibilityByAccident() {
        let store = StatisticsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var inputRequested = false
        var opened: SystemPermission?
        let monitor = InputMonitor(store: store, permissions: PermissionAccess(
            inputAllowed: { true }, accessibilityAllowed: { false },
            requestInput: { inputRequested = true }, requestAccessibility: {},
            openSettings: { opened = $0 }
        ))
        monitor.requestInputPermission()
        #expect(inputRequested)
        #expect(opened == .inputMonitoring)
        #expect(!store.accessibilityPermissionGranted)
        monitor.stop()
    }
}

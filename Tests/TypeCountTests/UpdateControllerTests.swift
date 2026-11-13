import Foundation
import XCTest
@testable import TypeCount

final class UpdateControllerTests: XCTestCase {
    @MainActor
    func testDemoNeverStartsOrChecksForUpdates() async {
        let controller = UpdateController(isDemo: true)
        controller.start()
        controller.start()
        controller.checkForUpdates()
        controller.setAutomaticallyChecksForUpdates(true)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertNil(controller.lastCheckDate)
        XCTAssertTrue(controller.status.contains("演示"))
    }

    @MainActor
    func testBareSwiftPackageDoesNotCreateAnUpdater() async {
        // Running via swift test must not launch Sparkle or touch a real feed.
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension.lowercased(), "app")
        let controller = UpdateController(bundle: .main)
        controller.start()
        controller.checkForUpdates()
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertNil(controller.lastCheckDate)
    }

    @MainActor
    func testConfigurationRequiresHttpsAndAnEd25519PublicKey() async {
        let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(UpdateController.hasValidConfiguration([
            "SUFeedURL": "https://github.com/example/app/releases/latest/download/appcast.xml",
            "SUPublicEDKey": publicKey
        ]))
        for feed in ["http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:password@example.com/appcast.xml"] {
            XCTAssertFalse(UpdateController.hasValidConfiguration(["SUFeedURL": feed, "SUPublicEDKey": publicKey]))
        }
        XCTAssertFalse(UpdateController.hasValidConfiguration(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "invalid"]))
        XCTAssertFalse(UpdateController.hasValidConfiguration(nil))
    }

    @MainActor
    func testBackgroundUpdateLaunchMarkerIsRecentAndConsumedOnce() async {
        let suite = "UpdateControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "sparkleBackgroundRelaunchPendingAt"
        defaults.set(now.addingTimeInterval(-10).timeIntervalSince1970, forKey: key)
        XCTAssertTrue(UpdateController.consumeBackgroundRelaunch(defaults: defaults, now: now))
        XCTAssertFalse(UpdateController.consumeBackgroundRelaunch(defaults: defaults, now: now))
        defaults.set(now.addingTimeInterval(-600).timeIntervalSince1970, forKey: key)
        XCTAssertFalse(UpdateController.consumeBackgroundRelaunch(defaults: defaults, now: now))
        defaults.set(now.addingTimeInterval(60).timeIntervalSince1970, forKey: key)
        XCTAssertFalse(UpdateController.consumeBackgroundRelaunch(defaults: defaults, now: now))
    }
}

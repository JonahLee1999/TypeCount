import Combine
import Foundation
import XCTest
@testable import TypeCount

final class StatisticsStoreTests: XCTestCase {
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TypeCountTests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    func testPeriodsUseLocalCalendarDaysAndIncludeZeroDays() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.one", name: "One", characters: 5, keystrokes: 10, at: date(13, hour: 0))
        store.record(bundleID: "app.one", name: "One", characters: 7, at: date(12, hour: 23))
        store.record(bundleID: "app.two", name: "Two", characters: 11, at: date(6))
        store.record(bundleID: "app.two", name: "Two", characters: 13, at: date(14))
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 5)
        XCTAssertEqual(store.snapshot.days.count, 7)
        XCTAssertEqual(store.todayCharacters, 5)
        store.selectedPeriod = .week
        XCTAssertEqual(store.snapshot.totalCharacters, 12)
        XCTAssertEqual(store.snapshot.applications.count, 1)
        store.selectedPeriod = .month
        XCTAssertEqual(store.snapshot.totalCharacters, 23)
        XCTAssertEqual(store.snapshot.days.count, 30)
    }

    @MainActor
    func testPauseExclusionsAndNegativeInputsCannotAddCounts() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.setExcluded("app.excluded", excluded: true)
        store.record(bundleID: "app.excluded", name: "Excluded", characters: 99, at: date(13))
        store.record(bundleID: StatisticsStore.ownBundleID, name: "Self", characters: 99, at: date(13))
        store.isPaused = true
        store.record(bundleID: "app.one", name: "One", characters: 99, at: date(13))
        store.isPaused = false
        store.record(bundleID: "app.one", name: "One", characters: -3, keystrokes: 4, at: date(13))
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 0)
        XCTAssertEqual(store.snapshot.totalKeystrokes, 4)
        store.setExcluded("app.excluded", excluded: false)
        store.record(bundleID: "app.excluded", name: "Included", characters: 3, at: date(13))
        store.refresh()
        XCTAssertEqual(store.snapshot.totalCharacters, 3)
    }

    @MainActor
    func testAtomicPersistenceRestoresCountsAndSettings() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.one", name: "One", characters: 12, keystrokes: 25, at: date(13))
        store.setExcluded("app.hidden", excluded: true)
        store.isPaused = true
        store.flush()
        XCTAssertNil(store.persistenceError)
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        restored.setDashboardVisible(true)
        XCTAssertEqual(restored.snapshot.totalCharacters, 12)
        XCTAssertEqual(restored.snapshot.totalKeystrokes, 25)
        XCTAssertTrue(restored.isPaused)
        XCTAssertTrue(restored.excludedBundleIDs.contains("app.hidden"))
        let file = directory.appendingPathComponent("stats.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "isPaused", "excludedBundleIDs", "records"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testCorruptHistoryIsPreservedRatherThanOverwritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("not valid json".utf8)
        let file = directory.appendingPathComponent("stats.json")
        try original.write(to: file)
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        XCTAssertNotNil(store.persistenceError)
        store.record(bundleID: "app.one", name: "One", characters: 3, at: date(13))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: file), original)
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 3)
        XCTAssertTrue(store.exportCSV().contains("app.one"))
    }

    @MainActor
    func testCSVQuotesNamesAndExportsHistoryOutsideSelectedPeriod() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.one", name: "App, \"One\"", characters: 5, at: date(1))
        store.record(bundleID: "app.two", name: "=FORMULA", characters: 7, at: date(13))
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 7)
        let csv = store.exportCSV()
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}日期,"))
        XCTAssertTrue(csv.contains("\"App, \"\"One\"\"\""))
        XCTAssertTrue(csv.contains("'=FORMULA"))
        XCTAssertTrue(csv.contains("2026-11-01"))
    }

    @MainActor
    func testDemoNeverPersistsOrAcceptsLiveCounts() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, demo: true, calendar: calendar(), now: { self.date(13) })
        store.setDashboardVisible(true)
        let original = store.snapshot.totalCharacters
        XCTAssertGreaterThan(original, 0)
        store.record(bundleID: "app.one", name: "One", characters: 100, at: date(13))
        store.flush()
        XCTAssertEqual(store.snapshot.totalCharacters, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testHiddenTypingBurstUpdatesMenuCountsWithoutPublishingDashboard() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        var dashboardChanges = 0
        let subscription = store.objectWillChange.sink { dashboardChanges += 1 }
        for _ in 0..<10_000 {
            store.record(bundleID: "app.one", name: "One", characters: 2, keystrokes: 3, at: date(13))
        }
        XCTAssertEqual(store.todayCharacters, 20_000)
        XCTAssertEqual(store.todayKeystrokes, 30_000)
        XCTAssertEqual(dashboardChanges, 0)
        XCTAssertTrue(store.snapshot.applications.isEmpty)
        store.refresh()
        XCTAssertEqual(dashboardChanges, 0)
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 20_000)
        XCTAssertEqual(store.snapshot.totalKeystrokes, 30_000)
        XCTAssertEqual(dashboardChanges, 1)
        store.refresh()
        XCTAssertEqual(dashboardChanges, 1, "An unchanged explicit refresh should not invalidate the view")
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testVisibleTypingBurstPublishesOneCoalescedSnapshot() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) },
                                    snapshotInterval: .milliseconds(20))
        store.setDashboardVisible(true)
        var dashboardChanges = 0
        let subscription = store.objectWillChange.sink { dashboardChanges += 1 }
        let snapshotPublished = expectation(description: "The coalesced snapshot contains the entire typing burst")
        let snapshotSubscription = store.$snapshot.dropFirst().sink { snapshot in
            if snapshot.totalCharacters == 1_000 { snapshotPublished.fulfill() }
        }
        for _ in 0..<1_000 {
            store.record(bundleID: "app.one", name: "One", characters: 1, at: date(13))
        }
        XCTAssertEqual(dashboardChanges, 0)
        // Wait for the actual publication; a loaded CI runner may resume either
        // sleeping task first, even when the snapshot's deadline was earlier.
        let result = await XCTWaiter.fulfillment(of: [snapshotPublished], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(dashboardChanges, 1)
        XCTAssertEqual(store.snapshot.totalCharacters, 1_000)
        withExtendedLifetime((subscription, snapshotSubscription)) {}
    }

    @MainActor
    func testRecentPeriodAggregationRemainsCorrectWithYearsOfHistory() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = date(13)
        let calendar = calendar()
        let store = StatisticsStore(directory: directory, calendar: calendar, now: { reference })
        for offset in 0..<1_200 {
            let day = calendar.date(byAdding: .day, value: -offset, to: reference)!
            store.record(bundleID: "app.one", name: offset == 0 ? "Renamed" : "Old Name",
                         characters: 2, keystrokes: 3, at: day)
            store.record(bundleID: "app.two", name: "Two", characters: 1, keystrokes: 2, at: day)
        }
        store.selectedPeriod = .week
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 21)
        XCTAssertEqual(store.snapshot.totalKeystrokes, 35)
        XCTAssertEqual(store.snapshot.applications.first?.name, "Renamed")
        XCTAssertEqual(store.snapshot.days.map(\.characters), Array(repeating: 3, count: 7))
        store.selectedPeriod = .month
        XCTAssertEqual(store.snapshot.totalCharacters, 90)
        XCTAssertEqual(store.snapshot.totalKeystrokes, 150)
        XCTAssertEqual(store.todayCharacters, 3)
    }

    @MainActor
    func testContinuousTypingCheckpointsAndFlushPreservesLatestState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = date(13)
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { reference }, saveInterval: .milliseconds(25))
        for _ in 0..<30 {
            store.record(bundleID: "app.one", name: "One", characters: 1, keystrokes: 2, at: reference)
            try await Task.sleep(for: .milliseconds(10))
        }
        let file = directory.appendingPathComponent("stats.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Continuous input must not postpone every save")
        store.record(bundleID: "app.one", name: "One", characters: 7, keystrokes: 9, at: reference)
        store.flush()
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { reference })
        XCTAssertEqual(restored.todayCharacters, 37)
        XCTAssertEqual(restored.todayKeystrokes, 69)
        XCTAssertNil(store.persistenceError)
    }

    @MainActor
    func testRuntimeReadabilityOnlyPublishesWhenShownAndNeverPersists() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.one", name: "One", keystrokes: 5, at: date(13))
        var dashboardChanges = 0
        let subscription = store.objectWillChange.sink { dashboardChanges += 1 }
        store.setTextReadability(bundleID: "app.one", readability: .unsupported)
        store.setTextReadability(bundleID: "app.one", readability: .unsupported)
        XCTAssertEqual(dashboardChanges, 0)
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.applications.first?.textReadability, .unsupported)
        store.flush()
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        restored.setDashboardVisible(true)
        XCTAssertEqual(restored.snapshot.applications.first?.textReadability, .unknown)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testTodayCountersRollOverWhileDashboardIsHidden() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reference = date(13, hour: 23)
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { reference })
        store.record(bundleID: "app.one", name: "One", characters: 6, at: reference)
        XCTAssertEqual(store.todayCharacters, 6)
        reference = date(14, hour: 0)
        XCTAssertEqual(store.todayCharacters, 0)
        store.record(bundleID: "app.one", name: "One", characters: 4, at: reference)
        XCTAssertEqual(store.todayCharacters, 4)
        store.selectedPeriod = .week
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 10)
    }

    @MainActor
    func testResetClearsHiddenHistoryAndPreservesSettingsAndPermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.old", name: "Old", characters: 40, keystrokes: 80, at: date(1))
        store.record(bundleID: "app.today", name: "Today", characters: 7, keystrokes: 13, at: date(13))
        store.selectedPeriod = .month
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 47)
        store.setDashboardVisible(false)
        store.isPaused = true
        store.setExcluded("app.excluded", excluded: true)
        store.inputPermissionGranted = true
        store.keyboardMonitoringAvailable = true
        store.accessibilityPermissionGranted = true
        store.monitorStatus = "监测中"
        var menuUpdates = 0
        let token = store.menuBarUpdates.sink { menuUpdates += 1 }

        XCTAssertTrue(store.resetStatistics())
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.todayCharacters, 0)
        XCTAssertEqual(store.todayKeystrokes, 0)
        XCTAssertEqual(store.snapshot, .empty, "A previously visible hidden snapshot must not retain old apps or chart values")
        XCTAssertEqual(menuUpdates, 1)
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.excludedBundleIDs, ["app.excluded"])
        XCTAssertEqual(store.selectedPeriod, .month)
        XCTAssertTrue(store.inputPermissionGranted)
        XCTAssertTrue(store.keyboardMonitoringAvailable)
        XCTAssertTrue(store.accessibilityPermissionGranted)
        XCTAssertEqual(store.monitorStatus, "监测中")
        XCTAssertEqual(store.exportCSV().components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 1)
        store.setDashboardVisible(true)
        XCTAssertEqual(store.snapshot.totalCharacters, 0)
        XCTAssertEqual(store.snapshot.totalKeystrokes, 0)
        XCTAssertTrue(store.snapshot.applications.isEmpty)
        XCTAssertTrue(store.snapshot.days.allSatisfy { $0.characters == 0 })
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        XCTAssertEqual(restored.todayCharacters, 0)
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.excludedBundleIDs, ["app.excluded"])
        let file = directory.appendingPathComponent("stats.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testResetDrainsQueuedCheckpointAndCannotReviveOldData() async throws {
        let directory = temporaryDirectory()
        let queue = DispatchQueue(label: "StatisticsStoreTests.blocked-writer")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        defer { release.signal(); try? FileManager.default.removeItem(at: directory) }
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) },
                                    saveInterval: .milliseconds(1), snapshotInterval: .milliseconds(20), persistenceQueue: queue)
        store.setDashboardVisible(true)
        store.record(bundleID: "app.old", name: "Old", characters: 99, keystrokes: 123, at: date(13))
        try await Task.sleep(for: .milliseconds(40)) // The checkpoint is queued behind the blocked writer.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { release.signal() }
        XCTAssertTrue(store.resetStatistics())
        XCTAssertEqual(store.snapshot.totalCharacters, 0)
        XCTAssertTrue(store.snapshot.applications.isEmpty)
        let empty = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        XCTAssertEqual(empty.todayCharacters, 0, "Returning success must mean the empty archive is already durable")
        store.record(bundleID: "app.new", name: "New", characters: 2, keystrokes: 3, at: date(13))
        try await Task.sleep(for: .milliseconds(100)) // Deliver old completions and the new checkpoint.
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        restored.setDashboardVisible(true)
        XCTAssertEqual(restored.todayCharacters, 2)
        XCTAssertEqual(restored.todayKeystrokes, 3)
        XCTAssertEqual(restored.snapshot.applications.map(\.id), ["app.new"])
        XCTAssertEqual(store.snapshot.totalCharacters, 2)
        XCTAssertNil(store.persistenceError)
        store.flush()
    }

    @MainActor
    func testFailedResetKeepsMemoryAndCanSaveAfterFilesystemRecovers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("directory is temporarily unavailable".utf8).write(to: directory)
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.keep", name: "Keep", characters: 11, keystrokes: 17, at: date(13))
        store.setDashboardVisible(true)
        let previous = store.snapshot
        XCTAssertFalse(store.resetStatistics())
        XCTAssertTrue(try XCTUnwrap(store.persistenceError).contains("重置统计失败"))
        XCTAssertEqual(store.snapshot, previous)
        XCTAssertEqual(store.todayCharacters, 11)
        XCTAssertTrue(store.exportCSV().contains("app.keep"))
        try FileManager.default.removeItem(at: directory)
        store.flush()
        XCTAssertNil(store.persistenceError)
        let restored = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        XCTAssertEqual(restored.todayCharacters, 11)
        XCTAssertEqual(restored.todayKeystrokes, 17)
        XCTAssertTrue(store.resetStatistics())
        XCTAssertEqual(store.todayCharacters, 0)
    }

    @MainActor
    func testResetRefusesCorruptArchiveAndDemoDoesNotTouchExistingArchive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("stats.json")
        let original = Data("unreadable original history".utf8)
        try original.write(to: file)
        let store = StatisticsStore(directory: directory, calendar: calendar(), now: { self.date(13) })
        store.record(bundleID: "app.keep", name: "Keep", characters: 8, at: date(13))
        XCTAssertFalse(store.resetStatistics())
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.todayCharacters, 8)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let demo = StatisticsStore(directory: directory, demo: true, calendar: calendar(), now: { self.date(13) })
        demo.setDashboardVisible(true)
        XCTAssertGreaterThan(demo.todayCharacters, 0)
        XCTAssertTrue(demo.resetStatistics())
        XCTAssertEqual(demo.todayCharacters, 0)
        XCTAssertEqual(demo.snapshot.totalCharacters, 0)
        XCTAssertTrue(demo.snapshot.applications.isEmpty)
        demo.flush()
        XCTAssertEqual(try Data(contentsOf: file), original)
        let absentDirectory = temporaryDirectory()
        let isolatedDemo = StatisticsStore(directory: absentDirectory, demo: true)
        XCTAssertTrue(isolatedDemo.resetStatistics())
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentDirectory.path))
    }
}

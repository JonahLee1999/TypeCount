import Combine
import Foundation
import XCTest
@testable import TypeCount

final class ActivityStatisticsStoreTests: XCTestCase {
    private func calendar() -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return result
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ActivityTests-\(UUID().uuidString)")
    }

    @MainActor
    func testPeriodsHoursAndKeysAreActualNewAggregates() async {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ActivityStatisticsStore(directory: path, calendar: calendar(), now: { self.date(13) })
        XCTAssertEqual(store.snapshot(for: .today), .empty)
        store.recordKey(0, at: date(13, hour: 9))
        store.recordKey(0, at: date(13, hour: 9))
        store.recordKey(1, at: date(13, hour: 23))
        store.recordKey(2, at: date(12, hour: 9))
        store.recordMouse(left: true, at: date(13))
        store.recordMouse(left: false, at: date(12))
        let today = store.snapshot(for: .today)
        XCTAssertEqual(today.totalKeystrokes, 3)
        XCTAssertEqual(today.leftClicks, 1)
        XCTAssertEqual(today.rightClicks, 0)
        XCTAssertEqual(today.hours.count, 24)
        XCTAssertEqual(today.hours[9].keystrokes, 2)
        XCTAssertEqual(today.hours[23].keystrokes, 1)
        XCTAssertEqual(today.keys, [KeyActivity(keyCode: 0, count: 2), KeyActivity(keyCode: 1, count: 1)])
        XCTAssertEqual(store.snapshot(for: .week).totalKeystrokes, 4)
        XCTAssertEqual(store.snapshot(for: .week).rightClicks, 1)
        XCTAssertEqual(store.todayMouseClicks, 1)
        XCTAssertEqual(store.todayKeystrokes, 3)
    }

    @MainActor
    func testHiddenBurstDoesNotPublishDashboardAndVisibleUpdatesCoalesce() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ActivityStatisticsStore(directory: path, calendar: calendar(), now: { self.date(13) })
        var updates = 0
        let token = store.objectWillChange.sink { updates += 1 }
        for _ in 0..<10_000 { store.recordKey(49, at: date(13)) }
        XCTAssertEqual(store.todayKeystrokes, 10_000)
        XCTAssertEqual(updates, 0)
        store.setVisible(true)
        let initial = updates
        for _ in 0..<100 { store.recordMouse(left: true, at: date(13)) }
        XCTAssertEqual(updates, initial)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(updates, initial + 1)
        store.recordKey(0, at: date(13))
        store.setVisible(false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(updates, initial + 1)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testFlushRestoresNumericOnlyArchiveWithPrivatePermissions() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ActivityStatisticsStore(directory: path, calendar: calendar(), now: { self.date(13) })
        store.recordKey(12, at: date(13, hour: 8))
        store.recordMouse(left: true, at: date(13))
        store.recordMouse(left: false, at: date(13))
        store.flush()
        XCTAssertNil(store.persistenceError)
        let restored = ActivityStatisticsStore(directory: path, calendar: calendar(), now: { self.date(13) })
        XCTAssertEqual(restored.snapshot(for: .today), store.snapshot(for: .today))
        let file = path.appendingPathComponent("activity.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "days"])
        let days = try XCTUnwrap(object["days"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(days.first).keys), ["day", "totalKeystrokes", "leftClicks", "rightClicks", "hours", "keys"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("stats.json").path))
    }

    @MainActor
    func testRetentionAndDayRolloverDoNotInventHistoricalDistributions() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        var current = date(13)
        let cal = calendar()
        let store = ActivityStatisticsStore(directory: path, calendar: cal, now: { current })
        let start = cal.startOfDay(for: current)
        for offset in 0..<400 {
            store.recordKey(0, at: cal.date(byAdding: .day, value: -offset, to: start)!)
        }
        store.recordKey(-1, at: current)
        store.recordKey(256, at: current)
        store.recordKey(1, at: cal.date(byAdding: .day, value: 1, to: current)!)
        store.flush()
        let file = path.appendingPathComponent("activity.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((object["days"] as? [Any])?.count, 365)
        XCTAssertEqual(store.snapshot(for: .month).totalKeystrokes, 30)
        XCTAssertEqual(store.todayKeystrokes, 1)
        current = cal.date(byAdding: .day, value: 1, to: current)!
        XCTAssertEqual(store.todayKeystrokes, 0)
        XCTAssertEqual(store.todayMouseClicks, 0)
        store.recordKey(2, at: current)
        XCTAssertEqual(store.todayKeystrokes, 1)
    }

    @MainActor
    func testCorruptArchiveIsPreservedAndDemoNeverWrites() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent("activity.json")
        let original = Data("broken activity archive".utf8)
        try original.write(to: file)
        let store = ActivityStatisticsStore(directory: path, calendar: calendar(), now: { self.date(13) })
        XCTAssertNotNil(store.persistenceError)
        store.recordKey(0, at: date(13))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(store.todayKeystrokes, 1)

        let demoPath = directory()
        defer { try? FileManager.default.removeItem(at: demoPath) }
        let demo = ActivityStatisticsStore(directory: demoPath, calendar: calendar(), now: { self.date(13) }, demo: true)
        let snapshot = demo.snapshot(for: .today)
        XCTAssertGreaterThan(snapshot.totalKeystrokes, 0)
        demo.recordKey(0, at: date(13))
        demo.recordMouse(left: true, at: date(13))
        demo.flush()
        XCTAssertEqual(demo.snapshot(for: .today), snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: demoPath.path))
    }
}

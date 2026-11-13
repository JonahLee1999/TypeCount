import Combine
import Darwin
import Foundation

struct HourActivity: Identifiable, Equatable, Sendable {
    var id: Int { hour }
    let hour: Int
    let keystrokes: Int
}

struct KeyActivity: Identifiable, Equatable, Sendable {
    var id: Int { keyCode }
    let keyCode: Int
    let count: Int
}

struct ActivitySnapshot: Equatable, Sendable {
    let totalKeystrokes: Int
    let leftClicks: Int
    let rightClicks: Int
    let hours: [HourActivity]
    let keys: [KeyActivity]

    static let empty = ActivitySnapshot(totalKeystrokes: 0, leftClicks: 0, rightClicks: 0,
                                       hours: (0..<24).map { HourActivity(hour: $0, keystrokes: 0) }, keys: [])
}

/// Unordered daily activity aggregates. Stores no text, event sequence, timestamps
/// within an hour, app identities, mouse positions, or clipboard contents.
@MainActor
final class ActivityStatisticsStore: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let menuBarUpdates = PassthroughSubject<Void, Never>()
    let isDemo: Bool
    private(set) var persistenceError: String?

    private let calendar: Calendar
    private let now: () -> Date
    private let fileURL: URL
    private let writer: ActivityAggregateWriter
    private var days: [String: ActivityDay] = [:]
    private var currentDay = ""
    private var currentInterval: DateInterval?
    private var retentionStart = ""
    private var visible = false
    private var pendingNotification: Task<Void, Never>?
    private var pendingCheckpoint: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var dirty = false
    private var persistenceBlocked = false
    var isVisible: Bool { visible }

    var todayMouseClicks: Int {
        updateDay()
        guard let day = days[currentDay] else { return 0 }
        return Self.add(day.leftClicks, day.rightClicks)
    }

    var todayKeystrokes: Int {
        updateDay()
        return days[currentDay]?.totalKeystrokes ?? 0
    }

    init(directory: URL? = nil, calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init, demo: Bool = false) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeCount", isDirectory: true)
        self.calendar = calendar
        self.now = now
        self.isDemo = demo
        self.fileURL = directory.appendingPathComponent("activity.json")
        self.writer = ActivityAggregateWriter(directory: directory)
        initializeDay()
        if demo { seedDemo() } else { load() }
    }

    func recordKey(_ code: Int, at date: Date = Date()) {
        guard !isDemo, (0...255).contains(code) else { return }
        updateDay()
        guard let key = acceptedDay(for: date) else { return }
        let hour = calendar.component(.hour, from: date)
        guard (0..<24).contains(hour) else { return }
        var day = days[key] ?? ActivityDay(day: key)
        day.totalKeystrokes = Self.add(day.totalKeystrokes, 1)
        day.hours[hour] = Self.add(day.hours[hour], 1)
        day.keys[String(code)] = Self.add(day.keys[String(code)] ?? 0, 1)
        days[key] = day
        changed()
    }

    func recordMouse(left: Bool, at date: Date = Date()) {
        guard !isDemo else { return }
        updateDay()
        guard let key = acceptedDay(for: date) else { return }
        var day = days[key] ?? ActivityDay(day: key)
        if left { day.leftClicks = Self.add(day.leftClicks, 1) }
        else { day.rightClicks = Self.add(day.rightClicks, 1) }
        days[key] = day
        changed()
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        pendingNotification?.cancel()
        pendingNotification = nil
        if visible { objectWillChange.send() }
    }

    func snapshot(for period: StatisticsPeriod) -> ActivitySnapshot {
        updateDay()
        let today = calendar.startOfDay(for: now())
        let start = calendar.date(byAdding: .day, value: -(period.dayCount - 1), to: today) ?? today
        let startID = dayID(start)
        var total = 0
        var left = 0
        var right = 0
        var hours = Array(repeating: 0, count: 24)
        var keys: [Int: Int] = [:]
        for (id, day) in days where id >= startID && id <= currentDay {
            total = Self.add(total, day.totalKeystrokes)
            left = Self.add(left, day.leftClicks)
            right = Self.add(right, day.rightClicks)
            for hour in 0..<24 { hours[hour] = Self.add(hours[hour], day.hours[hour]) }
            for (rawCode, count) in day.keys {
                guard let code = Int(rawCode) else { continue }
                keys[code] = Self.add(keys[code] ?? 0, count)
            }
        }
        return ActivitySnapshot(
            totalKeystrokes: total, leftClicks: left, rightClicks: right,
            hours: hours.enumerated().map { HourActivity(hour: $0.offset, keystrokes: $0.element) },
            keys: keys.map { KeyActivity(keyCode: $0.key, count: $0.value) }.sorted {
                $0.count == $1.count ? $0.keyCode < $1.keyCode : $0.count > $1.count
            }
        )
    }

    /// The queue drains earlier checkpoints before writing this latest snapshot.
    /// Call on application termination, before the main run loop exits.
    func flush() {
        pendingCheckpoint?.cancel()
        pendingCheckpoint = nil
        guard !isDemo, !persistenceBlocked, dirty || revision > persistedRevision else { return }
        updateDay()
        let error = writer.writeSynchronously(payload())
        persistenceError = error
        if error == nil {
            persistedRevision = revision
            dirty = false
        }
    }

    private func initializeDay() {
        let date = now()
        currentDay = dayID(date)
        currentInterval = calendar.dateInterval(of: .day, for: date)
        let start = calendar.startOfDay(for: date)
        retentionStart = dayID(calendar.date(byAdding: .day, value: -364, to: start) ?? start)
    }

    /// Normal event and menu-counter access use only a date-interval comparison
    /// and dictionary lookup. Pruning runs once when the local day changes.
    private func updateDay() {
        let date = now()
        if let interval = currentInterval, date >= interval.start && date < interval.end { return }
        initializeDay()
        let oldCount = days.count
        days = days.filter { $0.key >= retentionStart && $0.key <= currentDay }
        if oldCount != days.count { markDirty() }
        menuBarUpdates.send()
        scheduleNotification()
    }

    private func acceptedDay(for date: Date) -> String? {
        if let interval = currentInterval, date >= interval.start && date < interval.end { return currentDay }
        let id = dayID(date)
        guard id >= retentionStart && id <= currentDay else { return nil }
        return id
    }

    private func dayID(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func changed() {
        markDirty()
        menuBarUpdates.send()
        scheduleNotification()
    }

    private func markDirty() {
        revision &+= 1
        dirty = true
        scheduleCheckpoint()
    }

    private func scheduleNotification() {
        guard visible, pendingNotification == nil else { return }
        pendingNotification = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingNotification = nil
            if self.visible { self.objectWillChange.send() }
        }
    }

    private func scheduleCheckpoint() {
        guard !isDemo, !persistenceBlocked, pendingCheckpoint == nil else { return }
        pendingCheckpoint = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingCheckpoint = nil
            guard self.dirty else { return }
            let revision = self.revision
            let payload = self.payload()
            self.dirty = false
            self.writer.enqueue(payload) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, revision >= self.persistedRevision else { return }
                    self.persistenceError = error
                    if error == nil { self.persistedRevision = revision }
                    else { self.dirty = true; self.scheduleCheckpoint() }
                    self.scheduleNotification()
                }
            }
        }
    }

    private func payload() -> ActivityArchive {
        ActivityArchive(version: 1, days: days.values.sorted { $0.day < $1.day })
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8_000_000 else { throw ActivityArchiveError.invalid }
            let archive = try JSONDecoder().decode(ActivityArchive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw ActivityArchiveError.invalid }
            var loaded: [String: ActivityDay] = [:]
            for day in archive.days {
                guard valid(day), loaded[day.day] == nil else { throw ActivityArchiveError.invalid }
                if day.day >= retentionStart && day.day <= currentDay { loaded[day.day] = day }
            }
            days = loaded
            if archive.days.count != loaded.count { markDirty() }
        } catch {
            persistenceBlocked = true
            persistenceError = "活动统计文件无法读取，已保留原文件：\(error.localizedDescription)"
        }
    }

    private func valid(_ day: ActivityDay) -> Bool {
        guard day.day.count == 10, day.hours.count == 24,
              day.totalKeystrokes >= 0, day.leftClicks >= 0, day.rightClicks >= 0,
              day.hours.allSatisfy({ $0 >= 0 }), day.keys.count <= 256,
              day.keys.allSatisfy({ Int($0.key).map { (0...255).contains($0) } == true && $0.value > 0 }) else { return false }
        let parts = day.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayID(date) == day.day else { return false }
        return day.hours.reduce(0, Self.add) == day.totalKeystrokes &&
            day.keys.values.reduce(0, Self.add) == day.totalKeystrokes
    }

    private func seedDemo() {
        let today = calendar.startOfDay(for: now())
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let id = dayID(date)
            var day = ActivityDay(day: id)
            for hour in 8...20 { day.hours[hour] = (hour * 13 + offset * 23) % 150 + 20 }
            day.totalKeystrokes = day.hours.reduce(0, Self.add)
            day.keys = ["0": day.totalKeystrokes / 3, "1": day.totalKeystrokes / 4,
                        "49": day.totalKeystrokes - day.totalKeystrokes / 3 - day.totalKeystrokes / 4]
            day.leftClicks = 180 + offset * 17
            day.rightClicks = 9 + offset
            days[id] = day
        }
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}

private struct ActivityDay: Codable, Sendable {
    let day: String
    var totalKeystrokes = 0
    var leftClicks = 0
    var rightClicks = 0
    var hours = Array(repeating: 0, count: 24)
    var keys: [String: Int] = [:]
}

private struct ActivityArchive: Codable, Sendable {
    let version: Int
    let days: [ActivityDay]
}

private enum ActivityArchiveError: Error { case invalid }

/// All encoding and normal file I/O stay on one utility queue. Immutable
/// payloads cross the queue boundary; no observed store state does.
private final class ActivityAggregateWriter: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.jonah.TypeCount.activity-writer", qos: .utility)

    init(directory: URL) { self.directory = directory }

    func enqueue(_ payload: ActivityArchive, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { completion(self.write(payload)) }
    }

    func writeSynchronously(_ payload: ActivityArchive) -> String? {
        queue.sync { write(payload) }
    }

    private func write(_ payload: ActivityArchive) -> String? {
        let temporary = directory.appendingPathComponent(".activity-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let destination = directory.appendingPathComponent("activity.json")
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return nil
        } catch {
            return "活动统计保存失败：\(error.localizedDescription)"
        }
    }
}

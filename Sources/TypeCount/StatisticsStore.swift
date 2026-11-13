import AppKit
import Combine
import Darwin
import Foundation

enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        }
    }

    var dayCount: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

enum TextReadability: String, Sendable {
    case unknown
    case available
    case unsupported
    case secure
    case tooLarge
}

struct ApplicationStatistics: Identifiable, Equatable {
    let id: String
    let name: String
    let characters: Int
    let keystrokes: Int
    var textReadability: TextReadability = .unknown

    @MainActor var icon: NSImage? { ApplicationIconCache.icon(for: id) }
}

struct DailyStatistics: Identifiable, Equatable {
    let id: String
    let date: Date
    let characters: Int
}

struct StatisticsSnapshot: Equatable {
    let totalCharacters: Int
    let totalKeystrokes: Int
    let applications: [ApplicationStatistics]
    let days: [DailyStatistics]

    static let empty = StatisticsSnapshot(totalCharacters: 0, totalKeystrokes: 0, applications: [], days: [])
}

/// Persists daily numeric aggregates only. Text captured by the input monitor never enters this store.
@MainActor
final class StatisticsStore: ObservableObject {
    static let ownBundleID = "com.jonah.TypeCount"

    /// Menu subscribers can throttle this independently of expensive dashboard updates.
    let menuBarUpdates = PassthroughSubject<Void, Never>()

    @Published private(set) var snapshot: StatisticsSnapshot = .empty
    @Published var isPaused = false {
        didSet { if oldValue != isPaused { markForPersistence() } }
    }
    @Published var inputPermissionGranted = false
    @Published var keyboardMonitoringAvailable = false
    @Published var accessibilityPermissionGranted = false
    @Published var monitorStatus = "等待授予权限"
    @Published var excludedBundleIDs: Set<String> = [] {
        didSet { if oldValue != excludedBundleIDs { markForPersistence() } }
    }
    @Published var selectedPeriod: StatisticsPeriod = .today {
        didSet { if oldValue != selectedPeriod { snapshotDirty = true; refresh() } }
    }
    @Published private(set) var persistenceError: String?

    let isDemo: Bool
    private let directory: URL
    private let calendar: Calendar
    private let now: () -> Date
    private let saveInterval: Duration
    private let snapshotInterval: Duration
    private let writer: StatisticsFileWriter

    // One canonical record per app/day. The small daily index makes today's counters O(1).
    private var recordsByDay: [String: [String: PersistedRecord]] = [:]
    private var dailyTotals: [String: CountTotals] = [:]
    private var readabilityByApp: [String: TextReadability] = [:]
    private var currentDayID = ""
    private var currentDayInterval: DateInterval?
    private var dashboardVisible = false
    private var snapshotDirty = true
    private var pendingSnapshot: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var pendingWriteToken: UUID?
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var isLoading = true
    private var persistenceBlocked = false

    var todayCharacters: Int {
        _ = updateCurrentDay(reference: now())
        return dailyTotals[currentDayID]?.characters ?? 0
    }

    var todayKeystrokes: Int {
        _ = updateCurrentDay(reference: now())
        return dailyTotals[currentDayID]?.keystrokes ?? 0
    }

    init(
        directory: URL? = nil,
        demo: Bool = false,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() },
        saveInterval: Duration = .seconds(5),
        snapshotInterval: Duration = .milliseconds(500),
        persistenceQueue: DispatchQueue? = nil
    ) {
        let resolvedDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeCount", isDirectory: true)
        self.directory = resolvedDirectory
        self.writer = StatisticsFileWriter(directory: resolvedDirectory, queue: persistenceQueue)
        self.isDemo = demo
        self.calendar = calendar
        self.now = now
        self.saveInterval = saveInterval
        self.snapshotInterval = snapshotInterval
        _ = updateCurrentDay(reference: now())
        if demo {
            seedDemo()
            inputPermissionGranted = true
            keyboardMonitoringAvailable = true
            accessibilityPermissionGranted = true
            monitorStatus = "演示模式 · 示例数据"
        } else {
            load()
        }
        isLoading = false
    }

    func setDashboardVisible(_ visible: Bool) {
        dashboardVisible = visible
        if visible {
            refresh()
        } else {
            pendingSnapshot?.cancel()
            pendingSnapshot = nil
        }
    }

    func setExcluded(_ bundleID: String, excluded: Bool) {
        if excluded {
            excludedBundleIDs.insert(bundleID)
        } else {
            excludedBundleIDs.remove(bundleID)
        }
    }

    /// Runtime compatibility information is deliberately kept out of the persisted schema.
    func setTextReadability(bundleID: String, readability: TextReadability) {
        guard readabilityByApp[bundleID, default: .unknown] != readability else { return }
        readabilityByApp[bundleID] = readability
        snapshotDirty = true
        scheduleSnapshot()
    }

    func record(bundleID: String, name: String, characters: Int = 0, keystrokes: Int = 0, at date: Date = Date()) {
        guard !isDemo, !isPaused, !bundleID.isEmpty,
              bundleID != Self.ownBundleID, !excludedBundleIDs.contains(bundleID) else { return }
        let characters = max(0, characters)
        let keystrokes = max(0, keystrokes)
        guard characters > 0 || keystrokes > 0 else { return }
        _ = updateCurrentDay(reference: now())
        let day = dayID(for: date)
        var record = recordsByDay[day]?[bundleID]
            ?? PersistedRecord(day: day, bundleID: bundleID, name: name, characters: 0, keystrokes: 0)
        record.name = name.isEmpty ? bundleID : name
        record.characters += characters
        record.keystrokes += keystrokes
        recordsByDay[day, default: [:]][bundleID] = record
        dailyTotals[day, default: CountTotals()].characters += characters
        dailyTotals[day, default: CountTotals()].keystrokes += keystrokes
        snapshotDirty = true
        markForPersistence()
        scheduleSnapshot()
        menuBarUpdates.send()
    }

    /// Advances the local day, but constructs dashboard data only while its window is visible.
    func refresh() {
        if updateCurrentDay(reference: now()) { menuBarUpdates.send() }
        guard dashboardVisible else { return }
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        rebuildSnapshotIfNeeded()
    }

    /// Exports all available history, independent of dashboard visibility or the selected period.
    func exportCSV() -> String {
        let header = "日期,应用名称,Bundle ID,估算输入字符数,按键次数"
        let rows = recordsByDay.values.flatMap(\.values).sorted {
            $0.day == $1.day ? $0.bundleID < $1.bundleID : $0.day < $1.day
        }.map { record in
            [record.day, record.name, record.bundleID, String(record.characters), String(record.keystrokes)]
                .map(csvEscape).joined(separator: ",")
        }
        return "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    /// Termination uses a synchronous barrier: prior background writes finish before the latest state is saved.
    /// Normal keyboard input never encodes JSON or touches disk on the main thread.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !isDemo, !persistenceBlocked, revision > persistedRevision || pendingWriteToken != nil else { return }
        pendingWriteToken = nil // Ignore completion callbacks belonging to writes before this barrier.
        let error = writer.writeSynchronously(makePersistenceRequest())
        if error == nil { persistedRevision = revision }
        setPersistenceError(error)
    }

    /// A reset is committed only after the empty archive replaces all queued writes.
    /// Settings stay in that archive, and a failed replacement leaves live history intact.
    @discardableResult
    func resetStatistics() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        pendingWriteToken = nil // Fence completions already waiting for the main actor.

        guard !persistenceBlocked else {
            setPersistenceError("无法重置统计：本地统计文件无法读取，原文件和本次内存统计均已保留。请先导出 CSV 并处理原文件。")
            scheduleSnapshot()
            return false
        }
        if !isDemo {
            let empty = PersistenceRequest(isPaused: isPaused, excludedBundleIDs: excludedBundleIDs.sorted(), recordsByDay: [:])
            if let error = writer.writeSynchronously(empty) {
                setPersistenceError("重置统计失败，现有统计已保留，可恢复保存后重试。\(error)")
                markForPersistence()
                scheduleSnapshot()
                return false
            }
        }

        recordsByDay.removeAll()
        dailyTotals.removeAll()
        revision &+= 1
        persistedRevision = revision
        snapshotDirty = true
        _ = updateCurrentDay(reference: now())
        if dashboardVisible {
            rebuildSnapshotIfNeeded()
        } else if snapshot != .empty {
            snapshot = .empty
        }
        setPersistenceError(nil)
        menuBarUpdates.send()
        return true
    }

    private func scheduleSnapshot() {
        guard dashboardVisible, pendingSnapshot == nil else { return }
        let interval = snapshotInterval
        pendingSnapshot = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pendingSnapshot = nil
            guard self.dashboardVisible else { return }
            _ = self.updateCurrentDay(reference: self.now())
            self.rebuildSnapshotIfNeeded()
        }
    }

    private func rebuildSnapshotIfNeeded() {
        guard snapshotDirty else { return }
        let end = currentDayInterval?.start ?? calendar.startOfDay(for: now())
        let chartDayCount = max(7, selectedPeriod.dayCount)
        var applicationsByID: [String: ApplicationStatistics] = [:]
        var days: [DailyStatistics] = []
        days.reserveCapacity(chartDayCount)

        // Visit only the requested 1/7/30 daily buckets, never the entire stored history.
        for offset in (0..<chartDayCount).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let id = dayID(for: date)
            days.append(DailyStatistics(id: id, date: date, characters: dailyTotals[id]?.characters ?? 0))
            guard offset < selectedPeriod.dayCount, let records = recordsByDay[id] else { continue }
            for record in records.values {
                let existing = applicationsByID[record.bundleID]
                applicationsByID[record.bundleID] = ApplicationStatistics(
                    id: record.bundleID,
                    name: record.name,
                    characters: (existing?.characters ?? 0) + record.characters,
                    keystrokes: (existing?.keystrokes ?? 0) + record.keystrokes,
                    textReadability: readabilityByApp[record.bundleID, default: .unknown]
                )
            }
        }
        let applications = applicationsByID.values.sorted {
            if $0.characters != $1.characters { return $0.characters > $1.characters }
            if $0.keystrokes != $1.keystrokes { return $0.keystrokes > $1.keystrokes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let next = StatisticsSnapshot(
            totalCharacters: applications.reduce(0) { $0 + $1.characters },
            totalKeystrokes: applications.reduce(0) { $0 + $1.keystrokes },
            applications: applications,
            days: days
        )
        snapshotDirty = false
        if snapshot != next { snapshot = next }
    }

    private func markForPersistence() {
        guard !isLoading, !isDemo else { return }
        revision &+= 1
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isLoading, !isDemo, !persistenceBlocked,
              revision > persistedRevision, pendingSave == nil, pendingWriteToken == nil else { return }
        let interval = saveInterval
        // The deadline starts with the first dirty event and is never postponed by further typing.
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.enqueueSave()
        }
    }

    private func enqueueSave() {
        guard !persistenceBlocked, revision > persistedRevision, pendingWriteToken == nil else { return }
        let request = makePersistenceRequest()
        let savedRevision = revision
        let token = UUID()
        pendingWriteToken = token
        writer.write(request) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.pendingWriteToken == token else { return }
                self.pendingWriteToken = nil
                if error == nil { self.persistedRevision = savedRevision }
                self.setPersistenceError(error)
                self.scheduleSave()
            }
        }
    }

    private func makePersistenceRequest() -> PersistenceRequest {
        PersistenceRequest(isPaused: isPaused, excludedBundleIDs: excludedBundleIDs.sorted(), recordsByDay: recordsByDay)
    }

    private func setPersistenceError(_ message: String?) {
        if persistenceError != message { persistenceError = message }
    }

    private func load() {
        let fileURL = directory.appendingPathComponent("stats.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: fileURL))
            guard state.version == 1 else { throw StoreError.unsupportedVersion }
            var loaded: [String: [String: PersistedRecord]] = [:]
            var totals: [String: CountTotals] = [:]
            for record in state.records {
                guard record.characters >= 0, record.keystrokes >= 0,
                      record.day.count == 10, !record.bundleID.isEmpty,
                      loaded[record.day]?[record.bundleID] == nil else {
                    throw StoreError.invalidRecord
                }
                loaded[record.day, default: [:]][record.bundleID] = record
                totals[record.day, default: CountTotals()].characters += record.characters
                totals[record.day, default: CountTotals()].keystrokes += record.keystrokes
            }
            recordsByDay = loaded
            dailyTotals = totals
            isPaused = state.isPaused
            excludedBundleIDs = Set(state.excludedBundleIDs)
        } catch {
            // Never overwrite unreadable history, including from a newer unsupported schema.
            persistenceBlocked = true
            persistenceError = "无法读取本地统计文件，原文件已保留。本次新增统计暂存内存，请先导出 CSV。"
        }
    }

    @discardableResult
    private func updateCurrentDay(reference: Date) -> Bool {
        if let interval = currentDayInterval, reference >= interval.start, reference < interval.end { return false }
        currentDayInterval = calendar.dateInterval(of: .day, for: reference)
        currentDayID = uncachedDayID(for: reference)
        snapshotDirty = true
        return true
    }

    private func dayID(for date: Date) -> String {
        if let interval = currentDayInterval, date >= interval.start, date < interval.end { return currentDayID }
        return uncachedDayID(for: date)
    }

    private func uncachedDayID(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func csvEscape(_ value: String) -> String {
        let protected = ["=", "+", "-", "@", "\t"].contains(where: value.hasPrefix) ? "'" + value : value
        guard protected.contains(",") || protected.contains("\"") || protected.contains("\n") || protected.contains("\r") else { return protected }
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func seedDemo() {
        let apps = [("com.apple.TextEdit", "文本编辑", 1340), ("com.apple.Safari", "Safari", 786),
                    ("com.microsoft.VSCode", "Visual Studio Code", 514), ("com.apple.Notes", "备忘录", 268)]
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now()) else { continue }
            let day = dayID(for: date)
            for (index, app) in apps.enumerated() {
                let count = max(0, app.2 + ((offset * 177 + index * 39) % 719) - offset * 89)
                let record = PersistedRecord(day: day, bundleID: app.0, name: app.1, characters: count, keystrokes: count * 2 + 63)
                recordsByDay[day, default: [:]][app.0] = record
                dailyTotals[day, default: CountTotals()].characters += record.characters
                dailyTotals[day, default: CountTotals()].keystrokes += record.keystrokes
            }
        }
    }
}

private struct CountTotals {
    var characters = 0
    var keystrokes = 0
}

private struct PersistedRecord: Codable, Sendable {
    let day: String
    let bundleID: String
    var name: String
    var characters: Int
    var keystrokes: Int
}

private struct PersistedState: Codable, Sendable {
    let version: Int
    let isPaused: Bool
    let excludedBundleIDs: [String]
    let records: [PersistedRecord]
}

private struct PersistenceRequest: Sendable {
    let isPaused: Bool
    let excludedBundleIDs: [String]
    let recordsByDay: [String: [String: PersistedRecord]]
}

/// A single utility queue bounds concurrent copies and guarantees write ordering.
private final class StatisticsFileWriter: Sendable {
    private let directory: URL
    private let queue: DispatchQueue

    init(directory: URL, queue: DispatchQueue? = nil) {
        self.directory = directory
        self.queue = queue ?? DispatchQueue(label: "com.jonah.TypeCount.statistics", qos: .utility)
    }

    func write(_ request: PersistenceRequest, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [directory] in completion(Self.save(request, directory: directory)) }
    }

    func writeSynchronously(_ request: PersistenceRequest) -> String? {
        queue.sync { Self.save(request, directory: directory) }
    }

    private static func save(_ request: PersistenceRequest, directory: URL) -> String? {
        let temporary = directory.appendingPathComponent(".stats-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let payload = PersistedState(version: 1, isPaused: request.isPaused, excludedBundleIDs: request.excludedBundleIDs,
                                         records: request.recordsByDay.values.flatMap(\.values).sorted {
                                             $0.day == $1.day ? $0.bundleID < $1.bundleID : $0.day < $1.day
                                         })
            let encoder = JSONEncoder()
            // Compact JSON reduces bytes written; the version-1 schema remains unchanged.
            let data = try encoder.encode(payload)
            let fileURL = directory.appendingPathComponent("stats.json")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // Set private permissions before the atomic replacement, so an error
            // cannot be reported after the previous archive has already been replaced.
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return nil
        } catch {
            return "统计数据保存失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
private enum ApplicationIconCache {
    private final class Entry {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 1_048_576
        return cache
    }()

    static func icon(for bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            cache.setObject(Entry(nil), forKey: key, cost: 1)
            return nil
        }
        let original = NSWorkspace.shared.icon(forFile: url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        original.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 32, height: 32)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        cache.setObject(Entry(image), forKey: key, cost: 64 * 64 * 4)
        return image
    }
}

private enum StoreError: Error {
    case unsupportedVersion
    case invalidRecord
}

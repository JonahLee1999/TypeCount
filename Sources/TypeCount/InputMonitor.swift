import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Foundation

/// Keyboard events and AX notifications drive sampling. There is no idle text polling.
@MainActor
final class InputMonitor {
    private let store: StatisticsStore
    private let activity: ActivityStatisticsStore?
    private let permissions: PermissionAccess
    private let reader = AccessibleTextReader()
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var maintenanceTimer: Timer?
    private var sampleWork: DispatchWorkItem?
    private var reconciliationWork: DispatchWorkItem?
    private var reconciliationScheduledFor: Date?
    private var permissionRefreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObserver: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var app: NSRunningApplication?
    private var applicationElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var accumulator = TextInputAccumulator()
    private var compositionActivity = InputCompositionActivity()
    private let markingBegan = NSAccessibility.Notification.NSAccessibilityTextInputMarkingSessionBegan.rawValue
    private let markingEnded = NSAccessibility.Notification.NSAccessibilityTextInputMarkingSessionEnded.rawValue
    private var pendingKeys: [(code: Int, date: Date, verifiedSafe: Bool)] = []
    private var fieldVerifiedSafe = false
    private var lastTypingAt: Date? { compositionActivity.lastTypingAt }
    private var suppressUntil = Date.distantPast
    private var unsupportedRetryAt = Date.distantPast
    private var reconciliationAttempt = 0
    private var isRunning = false
    private var sessionActive = true

    init(store: StatisticsStore, permissions: PermissionAccess = .live, activity: ActivityStatisticsStore? = nil) {
        self.store = store
        self.permissions = permissions
        self.activity = activity
        store.$isPaused.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.configurationChanged() }
        }.store(in: &subscriptions)
        store.$excludedBundleIDs.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.configurationChanged() }
        }.store(in: &subscriptions)
    }

    func start() {
        guard !isRunning, !store.isDemo else { return }
        isRunning = true
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let left = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.mouseClicked(left: left) }
        }
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterActivation() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.prepareForegroundApplication() }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sessionActive = false
                    self.detachApplication()
                    self.removeEventTap(clearCapability: false)
                    self.setStatus("会话未激活，统计已暂停")
                }
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionActive = true
                    self?.refreshPermissions()
                }
            })
        }
        // Only permission/clock maintenance remains periodic. This never reads input text.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintenance() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
        refreshPermissions()
    }

    func stop() {
        if canRecordActivity { sample() }
        isRunning = false
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) }
        applicationObserver = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        detachApplication()
        removeEventTap()
    }

    func refreshPermissions() {
        guard !store.isDemo else { return }
        let input = permissions.inputAllowed()
        let accessibility = permissions.accessibilityAllowed()
        let changed = input != store.inputPermissionGranted || accessibility != store.accessibilityPermissionGranted
        if changed { detachApplication() }
        if store.inputPermissionGranted != input { store.inputPermissionGranted = input }
        if store.accessibilityPermissionGranted != accessibility { store.accessibilityPermissionGranted = accessibility }
        if isRunning && sessionActive && !store.isPaused && (input || accessibility) {
            installEventTap()
        } else {
            removeEventTap(clearCapability: !store.isPaused && sessionActive)
        }
        if !isRunning { return }
        if changed || app == nil {
            prepareForegroundApplication()
        }
    }

    func requestInputPermission() {
        permissions.requestInput()
        permissions.openSettings(.inputMonitoring)
        refreshAfterActivation()
    }

    func requestAccessibilityPermission() {
        permissions.requestAccessibility()
        permissions.openSettings(.accessibility)
        refreshAfterActivation()
    }

    func openPrivacySettings() {
        permissions.openSettings(store.keyboardMonitoringAvailable ? .accessibility : .inputMonitoring)
    }

    private func refreshAfterActivation() {
        refreshPermissions()
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            for delay in [500, 1000] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.refreshPermissions()
            }
        }
    }

    private func maintenance() {
        guard isRunning else { return }
        // No sample() here: the old 350ms polling loop kept waking idle editors.
        refreshPermissions()
        store.refresh()
    }

    private func configurationChanged() {
        detachApplication()
        if store.isPaused {
            removeEventTap(clearCapability: false)
            setStatus("统计已暂停")
        } else {
            refreshPermissions()
            prepareForegroundApplication()
        }
    }

    private func installEventTap() {
        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            setKeyboardCapability(CGEvent.tapIsEnabled(tap: tap))
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    MainActor.assumeIsolated {
                        // Source is attached only to the main run loop. This path
                        // only batches numbers; AX IPC and disk work are deferred.
                        Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                            .handleKey(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            setKeyboardCapability(false)
            setStatus("键盘监听未能启动，请检查权限或重新启动字迹")
            return
        }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setKeyboardCapability(CGEvent.tapIsEnabled(tap: tap))
    }

    private func removeEventTap(clearCapability: Bool = true) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventTap = nil
        eventSource = nil
        if clearCapability { setKeyboardCapability(false) }
    }

    private func setKeyboardCapability(_ available: Bool) {
        if store.keyboardMonitoringAvailable != available { store.keyboardMonitoringAvailable = available }
    }

    private func handleKey(type: CGEventType, event: CGEvent) {
        guard isRunning else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if store.inputPermissionGranted || store.accessibilityPermissionGranted, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard type == .keyDown, canRecordActivity else { return }
        let now = Date()
        if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            compositionActivity.reset()
            suppressUntil = now.addingTimeInterval(0.7)
            requestSample(after: 120)
            return
        }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard Self.isTypingKey(key) else {
            if key == 53 { accumulator.discardPending() }
            if key == 53 || !compositionActivity.hasActiveComposition(at: now) { compositionActivity.reset() }
            requestSample(after: 80)
            return
        }
        if pendingKeys.count < 256 { pendingKeys.append((key, now, fieldVerifiedSafe)) }
        if key == 48 { fieldVerifiedSafe = false } // Tab can move straight into a protected field.
        compositionActivity.recordKeyboard(at: now)
        requestSample(after: 80)
    }

    private var canRecordActivity: Bool {
        guard isRunning, sessionActive, !store.isPaused, store.keyboardMonitoringAvailable,
              let app, let bundleID = app.bundleIdentifier,
              !store.excludedBundleIDs.contains(bundleID) else { return false }
        if IsSecureEventInputEnabled() {
            store.setTextReadability(bundleID: bundleID, readability: .secure)
            pendingKeys.removeAll(keepingCapacity: true)
            clearText()
            setStatus("安全输入已启用，统计已暂停")
            return false
        }
        return true
    }

    private func mouseClicked(left: Bool) {
        guard canRecordActivity else { return }
        activity?.recordMouse(left: left)
        // A candidate click can commit an IME session without changing the
        // editing field. Keep that baseline until the next read verifies focus.
        let now = Date()
        if !left || !compositionActivity.recordCandidateClick(at: now) {
            compositionActivity.reset()
            suppressUntil = Date().addingTimeInterval(0.2)
        }
        unsupportedRetryAt = .distantPast
        requestSample(after: 100)
    }

    private static func isTypingKey(_ key: Int) -> Bool {
        switch key {
        case 0...51, 65, 67, 69, 75, 76, 78, 81...89, 91, 92, 117: return true
        default: return false
        }
    }

    private func prepareForegroundApplication() {
        guard isRunning else { return }
        let foreground = NSWorkspace.shared.frontmostApplication
        if foreground?.processIdentifier == app?.processIdentifier { return }
        detachApplication()
        guard sessionActive, !store.isPaused else { setStatus("统计已暂停"); return }
        guard store.keyboardMonitoringAvailable else { setStatus("等待辅助功能或输入监控授权"); return }
        guard let foreground, let bundleID = foreground.bundleIdentifier else { setStatus("等待前台应用"); return }
        guard foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              bundleID != StatisticsStore.ownBundleID else {
            setStatus("就绪 · 切换到其他 App 开始统计")
            return
        }
        guard !store.excludedBundleIDs.contains(bundleID) else { setStatus("当前 App 已排除"); return }
        app = foreground
        if store.accessibilityPermissionGranted {
            let element = AXUIElementCreateApplication(foreground.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.07)
            applicationElement = element
            attachObserver(pid: foreground.processIdentifier, element: element)
        }
        requestSample(after: 40)
    }

    private func attachObserver(pid: pid_t, element: AXUIElement) {
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, changed, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                    .accessibilityChanged(element: changed, notification: notification as String)
            }
        }, &created) == .success, let created else { return }
        observer = created
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification as String, kAXFocusedWindowChangedNotification as String,
                     markingBegan, markingEnded] {
            _ = AXObserverAddNotification(created, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func accessibilityChanged(element: AXUIElement, notification: String) {
        guard isRunning else { return }
        if notification == markingBegan || notification == markingEnded {
            guard canRecordActivity else { return }
            guard let focusedElement,
                  CFEqual(element, focusedElement) || applicationElement.map({ CFEqual(element, $0) }) == true else { return }
            let fromApplication = applicationElement.map { CFEqual(element, $0) } == true
            let now = Date()
            if notification == markingBegan {
                guard compositionActivity.markingBegan(fromApplication: fromApplication, at: now) else { return }
                requestSample(after: 40)
            } else {
                guard compositionActivity.markingEnded(at: now) else { return }
                // End also covers cancellation. Read the final value after the
                // editor has completed its replacement. It authorizes a read,
                // not a commit: an unknown Latin snapshot remains unverified.
                sampleWork?.cancel()
                sampleWork = nil
                requestSample(after: 80)
            }
        } else if notification == kAXValueChangedNotification {
            // Incoming messages and unrelated UI changes cannot trigger counting.
            let now = Date()
            compositionActivity.expire(at: now)
            guard compositionActivity.allowsTextRead(at: now) else {
                // Do not read unsolicited changes, and do not retain a stale
                // baseline that would charge those changes to the next key.
                invalidateRawBaseline()
                return
            }
            requestSample(after: 40)
        } else {
            // Duplicate focus/window notifications must not erase the baseline.
            // sample() compares actual AX element identity before changing it.
            unsupportedRetryAt = .distantPast
            requestSample(after: 40)
        }
    }

    private func observeValueChanges(on element: AXUIElement) {
        guard let observer else { return }
        if let observedElement, CFEqual(observedElement, element) { return }
        if let observedElement {
            for name in [kAXValueChangedNotification as String, markingBegan, markingEnded] {
                _ = AXObserverRemoveNotification(observer, observedElement, name as CFString)
            }
        }
        observedElement = element
        for name in [kAXValueChangedNotification as String, markingBegan, markingEnded] {
            _ = AXObserverAddNotification(observer, element, name as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func requestSample(after milliseconds: Int) {
        guard sampleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sampleWork = nil
            self.sample()
        }
        sampleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }

    private func sample() {
        guard canRecordActivity, let app, let bundleID = app.bundleIdentifier else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            prepareForegroundApplication()
            return
        }
        guard store.accessibilityPermissionGranted, let applicationElement else {
            flushPendingKeys()
            setStatus("仅统计按键 · 开启辅助功能后可读取支持的 App")
            return
        }
        if Date() < unsupportedRetryAt {
            flushPendingKeys()
            return
        }
        switch reader.focusedText(in: applicationElement) {
        case .unavailable(let reason):
            switch reason {
            case .secure:
                store.setTextReadability(bundleID: bundleID, readability: .secure)
                pendingKeys.removeAll(keepingCapacity: true)
                clearText()
                setStatus("安全输入框已保护，统计已暂停")
            case .tooLarge:
                flushPendingKeys()
                clearBaseline()
                store.setTextReadability(bundleID: bundleID, readability: .tooLarge)
                unsupportedRetryAt = Date().addingTimeInterval(3)
                setStatus("仅统计按键 · 当前文本过大")
            case .temporarilyUnavailable(let error):
                if error == .apiDisabled {
                    clearText()
                    refreshPermissions()
                } else {
                    flushPendingKeys()
                    clearBaseline()
                    unsupportedRetryAt = Date().addingTimeInterval(2)
                    setStatus("仅统计按键 · 当前 App 文本接口暂不可用")
                }
            default:
                flushPendingKeys()
                clearBaseline()
                store.setTextReadability(bundleID: bundleID, readability: .unsupported)
                unsupportedRetryAt = Date().addingTimeInterval(3)
                setStatus("仅统计按键 · 当前 App 未提供可读的输入文本")
            }
        case .readable(let snapshot):
            guard !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                clearText()
                return
            }
            let sameField = focusedElement.map { CFEqual($0, snapshot.element) } ?? false
            if !sameField {
                clearBaseline()
                focusedElement = snapshot.element
                observeValueChanges(on: snapshot.element)
            }
            flushPendingKeys()
            fieldVerifiedSafe = true
            store.setTextReadability(bundleID: bundleID, readability: .available)
            let now = Date()
            compositionActivity.expire(at: now)
            let canCount = compositionActivity.allowsTextRead(at: now)
            let composition: TextInputAccumulator.Composition
            let snapshotMarking: InputCompositionActivity.SnapshotMarking
            switch snapshot.composition {
            case .marked:
                composition = .marked
                snapshotMarking = .marked
            case .notMarked:
                composition = .committed
                snapshotMarking = .notMarked
            case .unknown:
                composition = compositionActivity.overridesUnknownAsMarked(at: now) ? .marked : .unknown
                snapshotMarking = .unknown
            }
            let count = accumulator.observe(text: snapshot.text, composition: composition,
                                            sameField: sameField, allowCounting: canCount && now >= suppressUntil,
                                            deferUnverifiedLatin: SystemInputSource.currentIsSystemPinyin())
            compositionActivity.didReadSnapshot(snapshotMarking, hasPendingDraft: accumulator.hasPendingVisibleText, at: now)
            if count > 0, let lastTypingAt {
                store.record(bundleID: bundleID, name: app.localizedName ?? bundleID, characters: count, at: lastTypingAt)
            }
            setStatus(accumulator.hasPendingVisibleText
                ? "正在确认输入法提交 · 字符可能延迟显示"
                : "正在统计 · 字符为文本变化估算")
            // At most three short tail checks for pending composition. Plain
            // committed input needs only one, and there is no idle polling.
            if reconciliationScheduledFor != lastTypingAt {
                reconciliationScheduledFor = lastTypingAt
                reconciliationAttempt = 0
            }
            let settling = compositionActivity.isSettling(at: now)
            let maximumAttempts = settling ? 3 : 1
            if canCount, reconciliationWork == nil, reconciliationAttempt < maximumAttempts {
                let delay = [120, 350, 800][reconciliationAttempt]
                reconciliationAttempt += 1
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.reconciliationWork = nil
                    self.requestSample(after: 0)
                }
                reconciliationWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
            }
        }
    }

    private func flushPendingKeys(onlyVerified: Bool = false) {
        guard let app, let bundleID = app.bundleIdentifier, !pendingKeys.isEmpty else { return }
        let pending = onlyVerified ? pendingKeys.filter(\.verifiedSafe) : pendingKeys
        pendingKeys.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        store.record(bundleID: bundleID, name: app.localizedName ?? bundleID,
                     keystrokes: pending.count, at: pending[0].date)
        for key in pending { activity?.recordKey(key.code, at: key.date) }
    }

    private func clearBaseline() {
        focusedElement = nil
        fieldVerifiedSafe = false
        accumulator.reset()
        compositionActivity.reset()
    }

    private func invalidateRawBaseline() {
        fieldVerifiedSafe = false
        accumulator.reset()
        compositionActivity.reset()
    }

    private func clearText() {
        if !store.isPaused, sessionActive, !IsSecureEventInputEnabled() {
            flushPendingKeys(onlyVerified: true)
        }
        sampleWork?.cancel()
        sampleWork = nil
        reconciliationWork?.cancel()
        reconciliationWork = nil
        reconciliationScheduledFor = nil
        reconciliationAttempt = 0
        pendingKeys.removeAll(keepingCapacity: true)
        clearBaseline()
    }

    private func detachApplication() {
        clearText()
        if let observer {
            if let observedElement {
                for name in [kAXValueChangedNotification as String, markingBegan, markingEnded] {
                    _ = AXObserverRemoveNotification(observer, observedElement, name as CFString)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedElement = nil
        applicationElement = nil
        app = nil
        unsupportedRetryAt = .distantPast
        suppressUntil = .distantPast
    }

    private func setStatus(_ value: String) {
        if store.monitorStatus != value { store.monitorStatus = value }
    }
}

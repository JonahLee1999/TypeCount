import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Carbon

@main
struct TypeCountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let demo = ProcessInfo.processInfo.arguments.contains("--demo")
    private var store: StatisticsStore!
    private var activity: ActivityStatisticsStore!
    private let launchAtLogin = LaunchAtLoginController()
    private var monitor: InputMonitor!
    private var updates: UpdateController!
    private var statusItem: NSStatusItem!
    private var dashboard: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var midnightTimer: Timer?
    private var lastMenuBadge: String?
    private var lastMenuPaused: Bool?
    private var lastMenuMetric: MenuBarMetric?
    private var activityWasVisibleBeforeHiding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = StatisticsStore(demo: demo)
        activity = ActivityStatisticsStore(demo: demo)
        monitor = InputMonitor(store: store, activity: activity)
        updates = UpdateController(isDemo: demo, onPrepareForInstallation: { [weak self] in
            self?.monitor?.stop()
            self?.store?.flush()
            self?.activity?.flush()
        }, onResumeAfterInstallationFailure: { [weak self] in
            self?.monitor?.start()
        })
        if !demo && !UserDefaults.standard.bool(forKey: "compactMenuBarDefaultV1") {
            UserDefaults.standard.set("compactCharacters", forKey: "menuBarMetric")
            UserDefaults.standard.set(true, forKey: "compactMenuBarDefaultV1")
        }
        if !demo && UserDefaults.standard.string(forKey: "menuBarMetric") == "characters" {
            UserDefaults.standard.set("compactCharacters", forKey: "menuBarMetric")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        Publishers.MergeMany([
            store.menuBarUpdates.eraseToAnyPublisher(),
            activity.menuBarUpdates.eraseToAnyPublisher(),
            store.$isPaused.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .map { _ in () }.eraseToAnyPublisher()
        ])
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.updateMenuBar() }
            .store(in: &subscriptions)
        scheduleMidnightRefresh()
        if !demo { monitor.start() }
        updates.start()
        updateMenuBar()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
            || event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        let updateRelaunch = UpdateController.consumeBackgroundRelaunch()
        if !loginLaunch && !updateRelaunch && !ProcessInfo.processInfo.arguments.contains("--background") { showDashboard() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        store?.flush()
        activity?.flush()
        midnightTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === dashboard else { return }
        store.setDashboardVisible(false)
        activity.setVisible(false)
        activityWasVisibleBeforeHiding = false
        // Release the SwiftUI scene graph while the menu bar app stays resident.
        closingWindow.contentView = nil
        dashboard = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) { syncDashboardVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { syncDashboardVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { syncDashboardVisibility() }
    func applicationDidHide(_ notification: Notification) { syncDashboardVisibility() }
    func applicationDidUnhide(_ notification: Notification) { syncDashboardVisibility() }

    private func syncDashboardVisibility() {
        let visible = dashboard.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } == true && !NSApp.isHidden
        store?.setDashboardVisible(visible)
        if !visible, activity?.isVisible == true {
            activityWasVisibleBeforeHiding = true
            activity.setVisible(false)
        } else if visible && activityWasVisibleBeforeHiding {
            activityWasVisibleBeforeHiding = false
            activity.setVisible(true)
        }
    }

    private func scheduleMidnightRefresh() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) else { return }
        let timer = Timer(fire: nextDay.addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refresh()
                self?.updateMenuBar()
                self?.scheduleMidnightRefresh()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func updateMenuBar() {
        guard let store, let button = statusItem?.button else { return }
        let metric = MenuBarMetric(rawValue: UserDefaults.standard.string(forKey: "menuBarMetric") ?? "") ?? .compactCharacters
        let badge: String?
        switch metric {
        case .compactCharacters: badge = MenuBarFormatting.compactCount(store.todayCharacters)
        case .iconOnly: badge = nil
        case .keystrokes: badge = MenuBarFormatting.compactCount(store.todayKeystrokes)
        case .mouseClicks: badge = MenuBarFormatting.compactCount(activity.todayMouseClicks)
        }
        // All display choices have the same fixed footprint. Only regenerate
        // when the visible abbreviation changes, rather than on every key.
        if lastMenuBadge != badge || lastMenuPaused != store.isPaused || lastMenuMetric != metric {
            lastMenuBadge = badge
            lastMenuPaused = store.isPaused
            lastMenuMetric = metric
            button.title = ""
            button.image = MenuBarIcon.image(badge: badge, paused: store.isPaused)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        button.setAccessibilityLabel("字迹\(store.isPaused ? "，已暂停" : "")，今日估算字符 \(store.todayCharacters.formatted())，按键 \(store.todayKeystrokes.formatted())，鼠标点击 \(activity.todayMouseClicks.formatted())")
        button.toolTip = "字迹\(store.isPaused ? " · 已暂停" : "")\n今日字符：≈\(store.todayCharacters.formatted())\n按键：\(store.todayKeystrokes.formatted()) 次 · 鼠标：\(activity.todayMouseClicks.formatted()) 次\n点击查看详情，右键打开菜单"
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let open = menu.addItem(withTitle: "打开统计主页", action: #selector(showDashboard), keyEquivalent: "")
            open.target = self
            let pause = menu.addItem(withTitle: store.isPaused ? "继续统计" : "暂停统计", action: #selector(togglePause), keyEquivalent: "")
            pause.target = self
            let check = menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            check.isEnabled = updates.canCheckForUpdates
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "退出字迹", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showDashboard()
        }
    }

    @objc private func togglePause() { store.isPaused.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { updates.checkForUpdates() }

    @objc private func showDashboard() {
        store.setDashboardVisible(true)
        launchAtLogin.refresh()
        if dashboard == nil {
            let content = DashboardView(
                store: store,
                launchAtLogin: launchAtLogin,
                activity: activity,
                updates: updates,
                onRequestInputPermission: { [weak self] in self?.monitor.requestInputPermission() },
                onRequestAccessibilityPermission: { [weak self] in self?.monitor.requestAccessibilityPermission() },
                onOpenPrivacySettings: { [weak self] in self?.monitor.openPrivacySettings() },
                onRefreshPermissions: { [weak self] in self?.monitor.refreshPermissions() },
                onRestartApp: { [weak self] in self?.restartApp() },
                onExport: { [weak self] in self?.exportStatistics() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = demo ? "字迹 · 演示数据" : "字迹"
            window.titleVisibility = .visible
            window.contentMinSize = NSSize(width: 480, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "zh_CN")))
            let frameName = demo ? "TypeCountCompactDashboardDemo" : "TypeCountCompactDashboard"
            window.setFrameAutosaveName(frameName)
            if !window.setFrameUsingName(frameName) { window.center() }
            dashboard = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
        if !demo { monitor.refreshPermissions() }
    }

    private func restartApp() {
        store.flush()
        activity.flush()
        let executable = URL(fileURLWithPath: "/bin/sh")
        let task = Process()
        task.executableURL = executable
        // Pass the bundle path as an argument, never interpolate it into shell code.
        // The separate short-lived process waits until this app has fully exited.
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$1\"", "typecount-relaunch", Bundle.main.bundleURL.path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能重新启动字迹"
            alert.informativeText = "请从菜单栏退出后，在应用程序文件夹重新打开字迹。"
            alert.runModal()
        }
    }

    private func exportStatistics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "字迹统计-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

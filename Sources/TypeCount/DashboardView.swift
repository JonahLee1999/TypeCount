import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: StatisticsStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var activity: ActivityStatisticsStore
    @ObservedObject var updates: UpdateController
    let onRequestInputPermission: () -> Void
    let onRequestAccessibilityPermission: () -> Void
    let onOpenPrivacySettings: () -> Void
    let onRefreshPermissions: () -> Void
    let onRestartApp: () -> Void
    let onExport: () -> Void
    let onResetStatistics: () -> Bool

    private enum StatisticsPane {
        case typing, activity

        var title: String {
            switch self {
            case .typing: "输入统计"
            case .activity: "键鼠活动"
            }
        }
    }

    @State private var selectedPane: StatisticsPane = .typing
    @State private var showingSettings = false
    @State private var checkForUpdatesAfterSettingsDismiss = false
    @State private var showingCountInfo = false
    @State private var showingTrend = false
    @State private var showingResetConfirmation = false
    @State private var resetStatisticsSucceeded = false
    @State private var lastPermissionCheck: Date?
    @AppStorage("menuBarMetric") private var menuBarMetricRaw = MenuBarMetric.compactCharacters.rawValue

    private struct ExclusionCandidate: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private var exclusionCandidates: [ExclusionCandidate] {
        var candidates = Dictionary(uniqueKeysWithValues: store.snapshot.applications.map {
            ($0.id, ExclusionCandidate(id: $0.id, name: $0.name, icon: $0.icon))
        })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != StatisticsStore.ownBundleID else { continue }
            candidates[bundleID] = ExclusionCandidate(id: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
        }
        for bundleID in store.excludedBundleIDs where candidates[bundleID] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            candidates[bundleID] = ExclusionCandidate(
                id: bundleID,
                name: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            )
        }
        return candidates.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private var needsPermission: Bool {
        !store.keyboardMonitoringAvailable || !store.accessibilityPermissionGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            periodPicker
            if selectedPane == .typing {
                summary
                if store.isDemo {
                    TypeNotice(text: "演示模式 · 示例数据，不监听键盘", symbol: "info.circle")
                    Divider()
                }
                if let error = store.persistenceError {
                    TypeNotice(text: error, symbol: "exclamationmark.triangle", isError: true)
                    Divider()
                }
                if needsPermission {
                    permissionNotice
                    Divider()
                }
                applicationList
                Divider()
                DisclosureGroup("最近 7 天", isExpanded: $showingTrend) {
                    TypeTrend(days: store.snapshot.days)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                ActivityDetailsView(store: activity, period: store.selectedPeriod, embedded: true)
            }
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 480, minHeight: 500)
        .sheet(isPresented: $showingSettings, onDismiss: settingsDidDismiss) { settings }
        .onAppear { activity.setVisible(selectedPane == .activity) }
        .onChange(of: selectedPane) { _, pane in
            activity.setVisible(pane == .activity)
        }
        .onDisappear { activity.setVisible(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("统计内容", selection: $selectedPane) {
                    Text("输入统计").tag(StatisticsPane.typing)
                    Text("键鼠活动").tag(StatisticsPane.activity)
                }
                .pickerStyle(.inline)
            } label: {
                Text(selectedPane.title).font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help("切换统计内容")
            .accessibilityLabel("统计内容")
            .accessibilityValue(selectedPane.title)
            Spacer()
            Button { store.isPaused.toggle() } label: {
                Image(systemName: store.isPaused ? "play" : "pause")
            }
            .help(store.isPaused ? "继续统计" : "暂停统计")
            .accessibilityLabel(store.isPaused ? "继续统计" : "暂停统计")
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help("设置").accessibilityLabel("设置")
            Menu {
                Button("检查更新…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                Divider()
                Button("导出统计为 CSV…", action: onExport)
                Divider()
                Button("重新检查权限", action: refreshPermissions)
                Button("打开系统隐私设置", action: onOpenPrivacySettings)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize().help("更多操作").accessibilityLabel("更多操作")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var periodPicker: some View {
        HStack {
            Picker("统计周期", selection: $store.selectedPeriod) {
                Text("今日").tag(StatisticsPeriod.today)
                Text("7 天").tag(StatisticsPeriod.week)
                Text("30 天").tag(StatisticsPeriod.month)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("≈\(store.snapshot.totalCharacters.formatted())")
                    .font(.system(size: 44, weight: .regular)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("估算字符").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 20) {
                Text("按键 \(store.snapshot.totalKeystrokes.formatted()) 次")
                Text("应用 \(store.snapshot.applications.count) 个")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 18)
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(store.keyboardMonitoringAvailable ? "需要辅助功能权限以估算字符。" : "键盘监听尚未启用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            Button("权限设置…") { showingSettings = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("应用")
                Spacer()
                Text("估算字符").frame(width: 90, alignment: .trailing)
                Text("按键").frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 9)
            Divider()
            if store.snapshot.applications.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无输入记录").font(.system(size: 13))
                    Text(needsPermission ? "开启权限后，在其他 App 中打字即可开始统计。" : "在其他 App 中打字，统计会显示在这里。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.snapshot.applications) { app in
                            TypeApplicationRow(app: app, excluded: store.excludedBundleIDs.contains(app.id))
                            if app.id != store.snapshot.applications.last?.id {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(store.isPaused || !store.keyboardMonitoringAvailable ? Color.secondary : Color.green)
                .frame(width: 5, height: 5)
            Text(store.monitorStatus).lineLimit(1).help(store.monitorStatus)
            Spacer(minLength: 8)
            Text("仅本机存储").fixedSize()
            Button { showingCountInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("统计口径").accessibilityLabel("统计口径")
                .popover(isPresented: $showingCountInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("统计口径").font(.system(size: 13, weight: .semibold))
                        Text("汉字、字母和标点各计 1，忽略空白。累计新增字符，删除不扣回。")
                        Text("中文预编辑、自动更正及部分编辑器可能存在误差。无法读取文本的 App 仅记录按键次数。")
                        Text("仅在本机保存数量，不保存文字内容。")
                    }
                    .font(.system(size: 12)).frame(width: 290, alignment: .leading).padding(18)
                }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var settings: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("完成") { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                Section("启动") {
                    Toggle("登录时启动字迹", isOn: Binding(
                        get: { launchAtLogin.isRegistered },
                        set: { requested in Task { await launchAtLogin.setEnabled(requested) } }
                    ))
                    .disabled(launchAtLogin.isUpdating || store.isDemo)
                    Text("登录启动后仅常驻菜单栏，不打开统计窗口。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 7) {
                        if launchAtLogin.isUpdating { ProgressView().controlSize(.small) }
                        Text(store.isDemo ? "演示模式下不更改登录启动设置。" : launchAtLogin.statusDescription)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = launchAtLogin.errorMessage {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(launchAtLogin.needsApproval ? "前往系统确认…" : "打开登录项设置…") {
                        launchAtLogin.openSystemSettings()
                    }
                    .controlSize(.small)
                }
                Section("显示") {
                    Picker("菜单栏显示", selection: $menuBarMetricRaw) {
                        ForEach(MenuBarMetric.allCases) { metric in
                            Text(metric.title).tag(metric.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("图标右上角显示缩写数字（如 1.9k），始终只占一个图标位置。悬停查看完整数值，点击查看详情。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("统计") {
                    Toggle("暂停所有统计", isOn: $store.isPaused)
                    Text("暂停期间不读取文本变化，也不记录按键。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("权限") {
                    permissionRow(
                        "键盘监听",
                        detail: store.keyboardMonitoringAvailable && !store.inputPermissionGranted
                            ? "已通过辅助功能启用，无需重复授权"
                            : "监听全局按键，用于统计键盘敲击",
                        granted: store.keyboardMonitoringAvailable,
                        action: onRequestInputPermission
                    )
                    permissionRow("辅助功能", detail: "读取支持的 App 内文本变化，用于估算字符", granted: store.accessibilityPermissionGranted, action: onRequestAccessibilityPermission)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已在系统设置中开启？返回后点重新检查；仍未识别可重新启动字迹。请确认列表里的应用来自 /Applications/字迹.app。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("重新检查", action: refreshPermissions)
                            Button("重新启动字迹", action: onRestartApp)
                        }
                        .controlSize(.small)
                        if let lastPermissionCheck {
                            Text("已重新检查 \(lastPermissionCheck.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Section {
                    if exclusionCandidates.isEmpty {
                        Text("打开需要排除的应用后，可在此选择。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(exclusionCandidates) { app in
                            Toggle(isOn: Binding(get: { store.excludedBundleIDs.contains(app.id) }, set: { store.setExcluded(app.id, excluded: $0) })) {
                                HStack(spacing: 8) {
                                    TypeAppIcon(image: app.icon, size: 20)
                                    Text(app.name).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("排除应用")
                } footer: {
                    Text("开启开关后，该应用不再新增统计，已有记录仍会保留。")
                }
                Section("更新") {
                    LabeledContent("当前版本", value: updates.currentVersion)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(updates.status)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = updates.lastCheckDate {
                            Text("上次检查 \(date.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Button("检查更新…") {
                            // Sparkle's installer asks the host to quit. Finish
                            // dismissing our modal sheet before starting its UI.
                            checkForUpdatesAfterSettingsDismiss = true
                            showingSettings = false
                        }
                            .disabled(!updates.canCheckForUpdates)
                    }
                    Toggle("自动检查新版本", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .disabled(!updates.isAvailable)
                    Text("检查更新会连接 GitHub。自动检查默认关闭，下载和安装由你确认，不上传输入内容或统计记录。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("本机数据") {
                    Text("仅保存按日、按应用汇总的数量，不保存文字内容。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("导出统计为 CSV…", action: onExport)
                    Button("重置统计数据…", role: .destructive) {
                        resetStatisticsSucceeded = false
                        showingResetConfirmation = true
                    }
                    .foregroundStyle(.red)
                    if resetStatisticsSucceeded {
                        Text(store.isDemo ? "示例统计已重置。" : "统计已重置，将从零开始记录。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 520, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("重置全部统计数据？", isPresented: $showingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("重置并重新统计", role: .destructive) {
                resetStatisticsSucceeded = onResetStatistics()
            }
        } message: {
            Text(store.isDemo
                 ? "演示数据，仅清空示例。不会影响真实统计或任何设置。"
                 : "将清空所有日期的估算字符、按键、各 App 记录，以及点击、小时和键位分布，从零开始。权限、开机自启、显示、排除和暂停设置会保留。历史无法恢复；输入历史可先导出 CSV。")
        }
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private func settingsDidDismiss() {
        guard checkForUpdatesAfterSettingsDismiss else { return }
        checkForUpdatesAfterSettingsDismiss = false
        updates.checkForUpdates()
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                Text(granted ? "已检测到授权" : "尚未检测到授权")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("打开设置", action: action).controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func refreshPermissions() {
        onRefreshPermissions()
        lastPermissionCheck = Date()
    }
}

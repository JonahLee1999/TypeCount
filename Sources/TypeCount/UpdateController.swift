import AppKit
import Combine
import Foundation
import Sparkle

/// Owns Sparkle for an installed app bundle. Initialization alone never starts
/// an updater, contacts the feed, or shows permission prompts.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isAvailable = false
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var latestAvailableVersion: String?

    let currentVersion: String
    let currentBuild: String
    let isDemo: Bool

    private let bundle: Bundle
    private let onPrepareForInstallation: () -> Void
    private let onResumeAfterInstallationFailure: () -> Void
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var preparedForInstallation = false
    private var relaunchRequested = false
    private var requestedStart = false
    private static let backgroundRelaunchKey = "sparkleBackgroundRelaunchPendingAt"

    init(bundle: Bundle = .main, isDemo: Bool = false,
         onPrepareForInstallation: @escaping () -> Void = {},
         onResumeAfterInstallationFailure: @escaping () -> Void = {}) {
        self.bundle = bundle
        self.isDemo = isDemo
        self.currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        self.currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        self.onPrepareForInstallation = onPrepareForInstallation
        self.onResumeAfterInstallationFailure = onResumeAfterInstallationFailure
        super.init()
        if isDemo { status = "演示模式不检查或安装更新" }
    }

    func start() {
        guard !requestedStart else { return }
        requestedStart = true
        guard !isDemo else { return }
        guard bundle.bundleURL.pathExtension.lowercased() == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            status = "请从字迹应用包检查更新"
            return
        }
        guard Self.hasValidConfiguration(bundle.infoDictionary) else {
            status = "更新配置暂不可用，请重新安装最新版字迹"
            return
        }
        let standard = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: self, userDriverDelegate: nil)
        controller = standard
        let updater = standard.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = enabled }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = enabled }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let date = change.newValue ?? nil
                Task { @MainActor [weak self] in self?.lastCheckDate = date }
            }
        ]
        // Initial defaults and privacy policy are in Info.plist. Only the user
        // settings action below changes Sparkle's persisted automatic-check choice.
        standard.startUpdater()
        isAvailable = true
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        guard let controller, isAvailable, controller.updater.canCheckForUpdates else { return }
        status = "正在检查更新…"
        latestAvailableVersion = nil
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater, isAvailable else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    /// Returns true once, only for the short interval following an update relaunch.
    /// Normal launches and login-item behavior keep their existing policy.
    static func consumeBackgroundRelaunch(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let timestamp = defaults.double(forKey: backgroundRelaunchKey)
        defaults.removeObject(forKey: backgroundRelaunchKey)
        let elapsed = now.timeIntervalSince1970 - timestamp
        return timestamp > 0 && elapsed >= 0 && elapsed < 300
    }

    static func hasValidConfiguration(_ info: [String: Any]?) -> Bool {
        guard let info, let rawFeed = info["SUFeedURL"] as? String,
              let feed = URL(string: rawFeed), feed.scheme?.lowercased() == "https",
              feed.host?.isEmpty == false, feed.user == nil, feed.password == nil,
              let publicKey = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latestAvailableVersion = item.displayVersionString
        status = "发现新版本 \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        latestAvailableVersion = nil
        status = "未发现适用于这台 Mac 的新版本"
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "正在下载 \(item.displayVersionString)…"
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        status = "下载完成，等待安装"
    }

    func userDidCancelDownload(_ updater: SPUUpdater) { status = "已取消下载，可随时重新检查" }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        status = "正在准备安装并重新启动…"
        prepareForInstallation()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareForInstallation()
        relaunchRequested = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.backgroundRelaunchKey)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        recordCompletion(error: error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        recordCompletion(error: error)
    }

    private func prepareForInstallation() {
        guard !preparedForInstallation else { return }
        preparedForInstallation = true
        onPrepareForInstallation()
    }

    private func recordCompletion(error: Error?) {
        // Sparkle may finish the update session as it starts terminating the
        // host. Preserve the relaunch marker and stopped monitor in that case.
        if error == nil && relaunchRequested { return }
        if let error {
            let error = error as NSError
            if error.domain == SUSparkleErrorDomain, error.code == SUError.noUpdateError.rawValue {
                status = "未发现适用于这台 Mac 的新版本"
            } else if error.domain == SUSparkleErrorDomain, error.code == SUError.installationCanceledError.rawValue {
                status = "已取消安装，可随时重新检查"
            } else {
                status = "更新未完成：\(error.localizedDescription)"
            }
        } else if latestAvailableVersion == nil {
            status = "检查已完成"
        }
        // Installation can fail or be cancelled while the host app stays alive.
        // Restore monitoring instead of leaving statistics stopped indefinitely.
        if preparedForInstallation {
            preparedForInstallation = false
            relaunchRequested = false
            UserDefaults.standard.removeObject(forKey: Self.backgroundRelaunchKey)
            onResumeAfterInstallationFailure()
        }
        if let updater = controller?.updater { canCheckForUpdates = updater.canCheckForUpdates }
    }
}

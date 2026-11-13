import Combine
import Foundation
import ServiceManagement

/// Separating the system service keeps tests from changing this Mac's login items.
@MainActor
protocol LaunchAtLoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
private final class MainAppLoginItemService: LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Reflects the system registration, rather than storing a separate preference.
/// Initialization and refresh only read status; registration requires an explicit setter call.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsApproval = false
    @Published private(set) var status: SMAppService.Status = .notRegistered

    private let service: any LaunchAtLoginService

    /// Includes a registration awaiting approval, so the user can also turn it off.
    /// `enabled` alone remains false until macOS says the app is eligible to launch.
    var isRegistered: Bool { enabled || needsApproval }

    var statusDescription: String {
        switch status {
        case .enabled:
            return "已启用，下次登录时自动启动。"
        case .requiresApproval:
            return "已登记，等待系统确认。请在登录项设置中允许字迹启动。"
        case .notRegistered:
            return "未启用。"
        case .notFound:
            return "系统暂时找不到此登录项。可开启开关重新注册，或前往系统登录项设置确认。"
        @unknown default:
            return "暂时无法确认登录启动状态，请在系统登录项设置中检查。"
        }
    }

    init(service: (any LaunchAtLoginService)? = nil) {
        self.service = service ?? MainAppLoginItemService()
        refresh()
    }

    func refresh() {
        guard !isUpdating else { return }
        let current = service.status
        if current != status { errorMessage = nil }
        apply(current)
    }

    func setEnabled(_ requested: Bool) async {
        guard !isUpdating else { return }
        errorMessage = nil
        apply(service.status)
        guard requested != isRegistered else { return }

        isUpdating = true
        defer {
            apply(service.status)
            isUpdating = false
        }
        // Let the explicit user action render its progress state before the system call.
        await Task.yield()
        do {
            if requested {
                try service.register()
            } else {
                try await service.unregister()
            }
            let result = service.status
            if requested && result != .enabled && result != .requiresApproval {
                errorMessage = "系统尚未确认登录启动，请在系统登录项设置中检查。"
            } else if !requested && (result == .enabled || result == .requiresApproval) {
                errorMessage = "系统仍保留此登录项，请在系统登录项设置中检查。"
            }
        } catch {
            errorMessage = Self.readableError(error, enabling: requested)
        }
    }

    func openSystemSettings() { service.openSystemSettings() }

    private func apply(_ current: SMAppService.Status) {
        if status != current { status = current }
        let isEnabled = current == .enabled
        let requiresApproval = current == .requiresApproval
        if enabled != isEnabled { enabled = isEnabled }
        if needsApproval != requiresApproval { needsApproval = requiresApproval }
    }

    private static func readableError(_ error: Error, enabling: Bool) -> String {
        let prefix = enabling ? "无法开启登录启动：" : "无法关闭登录启动："
        let systemError = error as NSError
        guard systemError.domain == SMAppServiceErrorDomain else {
            return prefix + systemError.localizedDescription
        }
        switch systemError.code {
        case Int(kSMErrorInvalidSignature):
            return prefix + "应用签名未通过系统验证，请从「应用程序」文件夹运行已签名的字迹后再试。"
        case Int(kSMErrorLaunchDeniedByUser), Int(kSMErrorAuthorizationFailure), Int(kSMErrorJobMustBeEnabled):
            return prefix + "需要系统允许，请打开登录项设置确认。"
        case Int(kSMErrorToolNotValid), Int(kSMErrorJobPlistNotFound), Int(kSMErrorJobNotFound):
            return prefix + "系统找不到此应用的登录启动项，请从「应用程序」文件夹运行字迹后再试。"
        case Int(kSMErrorServiceUnavailable):
            return prefix + "系统服务暂时不可用，请稍后重试。"
        default:
            return prefix + systemError.localizedDescription
        }
    }
}

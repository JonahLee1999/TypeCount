import AppKit
import ApplicationServices
import CoreGraphics

enum SystemPermission {
    case inputMonitoring
    case accessibility

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Keep OS prompts and navigation separate. A permission request is asynchronous
/// and is allowed to show no prompt after its first invocation.
@MainActor
struct PermissionAccess {
    var inputAllowed: () -> Bool
    var accessibilityAllowed: () -> Bool
    var requestInput: () -> Void
    var requestAccessibility: () -> Void
    var openSettings: (SystemPermission) -> Void

    static var live: PermissionAccess {
        PermissionAccess(
            inputAllowed: { CGPreflightListenEventAccess() },
            accessibilityAllowed: { AXIsProcessTrusted() },
            requestInput: { _ = CGRequestListenEventAccess() },
            requestAccessibility: {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            openSettings: { permission in
                if !NSWorkspace.shared.open(permission.settingsURL),
                   let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                    NSWorkspace.shared.openApplication(at: settings, configuration: .init())
                }
            }
        )
    }
}

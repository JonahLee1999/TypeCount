import Carbon
import Foundation

enum SystemInputSource {
    /// Identifies the selected Apple Pinyin mode, not its transient Shift/English state.
    /// This only reads input-source metadata and never changes the user's input method.
    @MainActor
    static func currentIsSystemPinyin() -> Bool {
        guard let unmanagedSource = TISCopyCurrentKeyboardInputSource() else { return false }
        let source = unmanagedSource.takeRetainedValue()
        return isSystemPinyin(
            sourceID: stringProperty(kTISPropertyInputSourceID, of: source),
            bundleID: stringProperty(kTISPropertyBundleID, of: source)
        )
    }

    static func isSystemPinyin(sourceID: String?, bundleID: String?) -> Bool {
        guard let sourceID, let bundleID else { return false }
        switch (bundleID, sourceID) {
        case ("com.apple.inputmethod.SCIM", "com.apple.inputmethod.SCIM.ITABC"),
             ("com.apple.inputmethod.SCIM", "com.apple.inputmethod.SCIM.Shuangpin"),
             ("com.apple.inputmethod.TCIM", "com.apple.inputmethod.TCIM.Pinyin"),
             ("com.apple.inputmethod.TCIM", "com.apple.inputmethod.TCIM.Shuangpin"):
            return true
        default:
            return false
        }
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
}

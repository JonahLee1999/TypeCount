import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Reads only the current input element, or an unambiguous editable descendant
/// of its focused container. Never searches windows or reads surrounding messages.
/// The caller owns snapshot lifetime and must discard text when focus is lost.
@MainActor
final class AccessibleTextReader {
    enum Source: String {
        case value
        case stringForRange
        case attributedStringForRange
    }

    enum Composition {
        case unknown
        case notMarked
        case marked
    }

    struct Snapshot {
        let element: AXUIElement
        let text: String
        let source: Source
        let composition: Composition
        var isSecure: Bool { false } // Secure elements never produce snapshots.
    }

    enum Readability {
        case noFocusedElement
        case unsupported
        case secure
        case tooLarge
        case ambiguous
        case temporarilyUnavailable(AXError)
    }

    enum ReadResult {
        case readable(Snapshot)
        case unavailable(Readability)
    }

    private struct Metadata {
        let element: AXUIElement
        let role: String?
        let isSecure: Bool
        let isFocused: Bool
        let selectedRange: CFRange?
        let characterCount: Int?
    }

    private struct ReadBudget {
        let started = Date()
        var calls = 0
        mutating func consume() -> Bool {
            guard calls < 120, Date().timeIntervalSince(started) < 0.30 else { return false }
            calls += 1
            return true
        }
    }

    private let maximumCharacters: Int
    private let messagingTimeout: Float
    private let maximumNodes = 24
    private let maximumDepth = 2

    init(maximumCharacters: Int = 100_000, messagingTimeout: Float = 0.07) {
        self.maximumCharacters = max(1, min(maximumCharacters, 100_000))
        self.messagingTimeout = max(0.05, min(messagingTimeout, 0.1))
    }

    func focusedText(in application: AXUIElement) -> ReadResult {
        guard !IsSecureEventInputEnabled() else { return .unavailable(.secure) }
        var budget = ReadBudget()
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let focus = attribute(kAXFocusedUIElementAttribute, of: application, budget: &budget)
        guard focus.error == .success, let rawFocus = focus.value,
              CFGetTypeID(rawFocus) == AXUIElementGetTypeID() else {
            if isMessagingFailure(focus.error) { return .unavailable(.temporarilyUnavailable(focus.error)) }
            return .unavailable(.noFocusedElement)
        }
        let root = unsafeDowncast(rawFocus, to: AXUIElement.self)
        guard let rootMetadata = metadata(for: root, budget: &budget) else {
            return .unavailable(.temporarilyUnavailable(.cannotComplete))
        }
        if rootMetadata.isSecure { return .unavailable(.secure) }

        var rootFailure: Readability = .unsupported
        if isDirectInput(rootMetadata, budget: &budget) {
            switch read(rootMetadata, budget: &budget) {
            case .readable(let snapshot): return .readable(snapshot)
            case .unavailable(.secure): return .unavailable(.secure)
            case .unavailable(.tooLarge): return .unavailable(.tooLarge)
            case .unavailable(let reason): rootFailure = reason
            }
        }

        // A focused window, application, web document or message list is not an
        // input container. Do not widen this search to the whole conversation.
        guard mayContainFocusedInput(rootMetadata.role) else { return .unavailable(rootFailure) }
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var candidates: [Metadata] = []
        var truncated = false

        while !queue.isEmpty, visited.count < maximumNodes {
            let item = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, item.element) }) { continue }
            visited.append(item.element)
            let current: Metadata
            if item.depth == 0 {
                current = rootMetadata
            } else {
                guard let result = metadata(for: item.element, budget: &budget) else {
                    return .unavailable(.temporarilyUnavailable(.cannotComplete))
                }
                current = result
                // Fail closed before any value read if the focused subtree
                // exposes a secure/protected descendant.
                if current.isSecure { return .unavailable(.secure) }
                if isEditableDescendant(current, budget: &budget) { candidates.append(current) }
            }
            guard item.depth < maximumDepth, mayContainFocusedInput(current.role) else { continue }
            let capacity = maximumNodes - visited.count - queue.count
            guard capacity > 0 else { truncated = true; continue }
            let result = children(of: item.element, limit: capacity, budget: &budget)
            truncated = truncated || result.truncated
            queue.append(contentsOf: result.elements.map { ($0, item.depth + 1) })
        }
        if !queue.isEmpty { truncated = true }
        let focusedCandidates = candidates.filter(\.isFocused)
        if focusedCandidates.count == 1 { return read(focusedCandidates[0], budget: &budget) }
        if focusedCandidates.count > 1 || candidates.count > 1 { return .unavailable(.ambiguous) }
        guard !truncated else { return .unavailable(.unsupported) }
        if let candidate = candidates.first { return read(candidate, budget: &budget) }
        return .unavailable(rootFailure)
    }

    private func metadata(for element: AXUIElement, budget: inout ReadBudget) -> Metadata? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard budget.consume() else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXFocusedAttribute,
                     "AXContainsProtectedContent", kAXSelectedTextRangeAttribute,
                     kAXNumberOfCharactersAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
        guard error == .success, let raw = values as? [Any], raw.count == 6 else { return nil }
        let role = raw[0] as? String
        let subrole = raw[1] as? String
        let secure = subrole == kAXSecureTextFieldSubrole as String || (raw[3] as? NSNumber)?.boolValue == true
        let focused = (raw[2] as? NSNumber)?.boolValue == true
        let count = (raw[5] as? NSNumber)?.intValue
        return Metadata(element: element, role: role, isSecure: secure, isFocused: focused,
                        selectedRange: Self.range(from: raw[4] as CFTypeRef),
                        characterCount: count.flatMap { $0 >= 0 ? $0 : nil })
    }

    private func isDirectInput(_ metadata: Metadata, budget: inout ReadBudget) -> Bool {
        if Self.isTextRole(metadata.role) { return true }
        // Some custom editors expose a focused AXGroup, a caret and a length.
        // Requiring editability avoids treating a selected message as an editor.
        return metadata.selectedRange != nil && metadata.characterCount != nil &&
            isValueSettable(metadata.element, budget: &budget)
    }

    private func isEditableDescendant(_ metadata: Metadata, budget: inout ReadBudget) -> Bool {
        guard Self.isTextRole(metadata.role) ||
                (metadata.selectedRange != nil && metadata.characterCount != nil) else { return false }
        return metadata.isFocused || isValueSettable(metadata.element, budget: &budget)
    }

    private static func isTextRole(_ role: String?) -> Bool {
        role == kAXTextAreaRole as String || role == kAXTextFieldRole as String || role == kAXComboBoxRole as String
    }

    private func mayContainFocusedInput(_ role: String?) -> Bool {
        // In particular, AXWindow/AXApplication/AXWebArea/AXList are excluded.
        guard let role else { return false }
        return ["AXGroup", "AXScrollArea", "AXLayoutArea", "AXSplitGroup", "AXUnknown",
                kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role)
    }

    private func isValueSettable(_ element: AXUIElement, budget: inout ReadBudget) -> Bool {
        guard budget.consume() else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private func read(_ metadata: Metadata, budget: inout ReadBudget) -> ReadResult {
        guard !metadata.isSecure, !IsSecureEventInputEnabled() else { return .unavailable(.secure) }
        if let count = metadata.characterCount, count > maximumCharacters { return .unavailable(.tooLarge) }
        let element = metadata.element
        let value = attribute(kAXValueAttribute, of: element, budget: &budget)
        if value.error == .success, let value = value.value {
            if let text = Self.plainText(from: value, maximumLength: maximumCharacters) {
                return snapshot(element, text: text, source: .value, budget: &budget)
            }
            if Self.textLength(of: value).map({ $0 > maximumCharacters }) == true { return .unavailable(.tooLarge) }
        } else if isMessagingFailure(value.error) {
            return .unavailable(.temporarilyUnavailable(value.error))
        }

        // Range APIs must have an explicit bounded full-field length. Never ask
        // for an arbitrary range or use selected text as a full input snapshot.
        guard let count = metadata.characterCount else { return .unavailable(.unsupported) }
        var range = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return .unavailable(.unsupported) }
        for (name, source) in [(kAXStringForRangeParameterizedAttribute, Source.stringForRange),
                               (kAXAttributedStringForRangeParameterizedAttribute, Source.attributedStringForRange)] {
            guard budget.consume() else { return .unavailable(.temporarilyUnavailable(.cannotComplete)) }
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
            if error == .success, let value {
                if let text = Self.plainText(from: value, maximumLength: maximumCharacters) {
                    return snapshot(element, text: text, source: source, budget: &budget)
                }
                if Self.textLength(of: value).map({ $0 > maximumCharacters }) == true { return .unavailable(.tooLarge) }
            } else if isMessagingFailure(error) {
                return .unavailable(.temporarilyUnavailable(error))
            }
        }
        return .unavailable(.unsupported)
    }

    private func snapshot(_ element: AXUIElement, text: String, source: Source,
                          budget: inout ReadBudget) -> ReadResult {
        let composition = composition(of: element, budget: &budget)
        guard !IsSecureEventInputEnabled() else { return .unavailable(.secure) }
        return .readable(Snapshot(element: element, text: text, source: source, composition: composition))
    }

    private func composition(of element: AXUIElement, budget: inout ReadBudget) -> Composition {
        // Public AppKit attribute, not supported by every editor or input method.
        let marked = attribute("AXTextInputMarkedRange", of: element, budget: &budget)
        if let value = marked.value, let range = Self.range(from: value) {
            return range.location != kCFNotFound && range.length > 0 ? .marked : .notMarked
        }
        // WebKit may expose an opaque marked-text marker range instead.
        let marker = attribute(kAXTextInputMarkedTextMarkerRangeAttribute, of: element, budget: &budget)
        if marker.error == .success, marker.value != nil { return .marked }
        return .unknown
    }

    private func children(of element: AXUIElement, limit: Int,
                          budget: inout ReadBudget) -> (elements: [AXUIElement], truncated: Bool) {
        guard limit > 0, budget.consume() else { return ([], true) }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0 else { return ([], false) }
        guard budget.consume() else { return ([], true) }
        var values: CFArray?
        let requested = min(count, limit)
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, requested, &values) == .success,
              let raw = values as? [AnyObject] else { return ([], true) }
        let elements = raw.compactMap { value -> AXUIElement? in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        return (elements, count > requested)
    }

    private func attribute(_ name: String, of element: AXUIElement,
                           budget: inout ReadBudget) -> (value: CFTypeRef?, error: AXError) {
        guard budget.consume() else { return (nil, .cannotComplete) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value, error)
    }

    private func isMessagingFailure(_ error: AXError) -> Bool {
        error == .apiDisabled || error == .cannotComplete || error == .invalidUIElement
    }

    private static func range(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private static func textLength(of value: CFTypeRef) -> Int? {
        if let attributed = value as? NSAttributedString { return attributed.length }
        if let string = value as? NSString { return string.length }
        return nil
    }

    private static func plainText(from value: CFTypeRef, maximumLength: Int) -> String? {
        if let attributed = value as? NSAttributedString {
            guard attributed.length <= maximumLength else { return nil }
            return attributed.string
        }
        if let string = value as? NSString {
            guard string.length <= maximumLength else { return nil }
            return string as String
        }
        return nil
    }
}

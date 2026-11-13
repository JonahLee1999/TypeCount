import Foundation

/// Field-scoped eligibility for AX reads. Notifications never create keyboard
/// activity, and observing a draft never extends its lifetime by itself.
struct InputCompositionActivity {
    enum SnapshotMarking { case unknown, marked, notMarked }
    private enum NotificationMarking { case none, marked, ended }

    private static let typingLifetime: TimeInterval = 1.5
    private static let compositionLifetime: TimeInterval = 30

    private(set) var lastTypingAt: Date?
    private(set) var lastSnapshotWasMarked = false
    private var lastKeyboardAt: Date?
    private var compositionActivityAt: Date?
    private var notificationMarking = NotificationMarking.none
    private var hasPendingDraft = false

    mutating func recordKeyboard(at now: Date) {
        expire(at: now)
        let hadComposition = lastSnapshotWasMarked || hasPendingDraft || notificationMarking != .none
        lastTypingAt = now
        lastKeyboardAt = now
        if notificationMarking == .ended { notificationMarking = .none }
        if hadComposition { compositionActivityAt = now }
    }

    /// Application-root notifications can continue an already field-bound
    /// session, but cannot start one for an unspecified editor.
    mutating func markingBegan(fromApplication: Bool, at now: Date) -> Bool {
        expire(at: now)
        let active = hasActiveComposition(at: now)
        guard active || (!fromApplication && isRecent(lastKeyboardAt, at: now, lifetime: Self.typingLifetime)) else {
            return false
        }
        if !active { compositionActivityAt = lastTypingAt }
        notificationMarking = .marked
        return true
    }

    mutating func markingEnded(at now: Date) -> Bool {
        expire(at: now)
        guard hasActiveComposition(at: now), notificationMarking != .ended else { return false }
        notificationMarking = .ended
        return true
    }

    mutating func recordCandidateClick(at now: Date) -> Bool {
        expire(at: now)
        guard hasActiveComposition(at: now),
              lastSnapshotWasMarked || hasPendingDraft || notificationMarking == .marked else { return false }
        lastTypingAt = now
        compositionActivityAt = now
        return true
    }

    func allowsTextRead(at now: Date) -> Bool {
        isRecent(lastTypingAt, at: now, lifetime: Self.typingLifetime) || hasActiveComposition(at: now)
    }

    func hasActiveComposition(at now: Date) -> Bool {
        isRecent(compositionActivityAt, at: now, lifetime: Self.compositionLifetime)
    }

    func overridesUnknownAsMarked(at now: Date) -> Bool {
        hasActiveComposition(at: now) && notificationMarking == .marked
    }

    func isSettling(at now: Date) -> Bool {
        hasActiveComposition(at: now) &&
            (lastSnapshotWasMarked || hasPendingDraft || notificationMarking != .none)
    }

    mutating func didReadSnapshot(_ marking: SnapshotMarking, hasPendingDraft: Bool, at now: Date) {
        expire(at: now)
        lastSnapshotWasMarked = marking == .marked
        self.hasPendingDraft = hasPendingDraft
        if marking == .notMarked {
            clearComposition()
        } else if lastSnapshotWasMarked || hasPendingDraft {
            if isRecent(lastTypingAt, at: now, lifetime: Self.typingLifetime) {
                compositionActivityAt = lastTypingAt
            }
        } else if notificationMarking != .marked {
            clearComposition()
        }
    }

    mutating func expire(at now: Date) {
        if compositionActivityAt != nil, !hasActiveComposition(at: now) { clearComposition() }
    }

    mutating func reset() {
        lastTypingAt = nil
        lastKeyboardAt = nil
        lastSnapshotWasMarked = false
        clearComposition()
    }

    private mutating func clearComposition() {
        compositionActivityAt = nil
        notificationMarking = .none
        hasPendingDraft = false
        lastSnapshotWasMarked = false
    }

    private func isRecent(_ date: Date?, at now: Date, lifetime: TimeInterval) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed <= lifetime
    }
}

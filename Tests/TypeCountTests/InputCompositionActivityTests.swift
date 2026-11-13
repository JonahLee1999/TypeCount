import Foundation
import Testing
@testable import TypeCount

struct InputCompositionActivityTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func notificationsWithoutAKeyboardCannotCreateTyping() {
        var activity = InputCompositionActivity()
        #expect(activity.markingBegan(fromApplication: false, at: start) == false)
        #expect(activity.markingBegan(fromApplication: true, at: start) == false)
        #expect(activity.markingEnded(at: start) == false)
        #expect(!activity.allowsTextRead(at: start))
        #expect(activity.lastTypingAt == nil)
    }

    @Test func applicationRootCannotStartAnUnboundSession() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: true, at: start.addingTimeInterval(0.1)) == false)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.2)) == true)
        #expect(activity.markingBegan(fromApplication: true, at: start.addingTimeInterval(0.3)) == true)
    }

    @Test func endingIsOneShotAndDoesNotManufactureAKeyboardDate() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.1)) == true)
        #expect(activity.markingEnded(at: start.addingTimeInterval(2)) == true)
        #expect(activity.markingEnded(at: start.addingTimeInterval(2.1)) == false)
        #expect(activity.lastTypingAt == start)
        #expect(!activity.overridesUnknownAsMarked(at: start.addingTimeInterval(2.2)))
        activity.didReadSnapshot(.unknown, hasPendingDraft: false, at: start.addingTimeInterval(2.2))
        #expect(!activity.hasActiveComposition(at: start.addingTimeInterval(2.3)))
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(2.3)))
    }

    @Test func aLostEndCannotFreezeUnknownTextForever() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.1)) == true)
        activity.didReadSnapshot(.unknown, hasPendingDraft: false, at: start.addingTimeInterval(0.2))
        #expect(!activity.lastSnapshotWasMarked)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(20)) == true)
        #expect(activity.overridesUnknownAsMarked(at: start.addingTimeInterval(29)))
        activity.expire(at: start.addingTimeInterval(31))
        #expect(!activity.overridesUnknownAsMarked(at: start.addingTimeInterval(31)))
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(31)))
        #expect(activity.markingEnded(at: start.addingTimeInterval(31)) == false)
    }

    @Test func markedMetadataWithoutUserInputCannotAuthorizeReads() {
        var activity = InputCompositionActivity()
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start)
        #expect(activity.lastSnapshotWasMarked)
        #expect(!activity.allowsTextRead(at: start))
        #expect(activity.markingEnded(at: start) == false)
        #expect(activity.recordCandidateClick(at: start) == false)
    }

    @Test func repeatedMarkedSnapshotsDoNotExtendEligibility() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start.addingTimeInterval(0.1))
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start.addingTimeInterval(20))
        #expect(activity.allowsTextRead(at: start.addingTimeInterval(29)))
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(31)))
        activity.expire(at: start.addingTimeInterval(31))
        #expect(activity.markingEnded(at: start.addingTimeInterval(31)) == false)
    }

    @Test func onlyRelatedClicksCanRenewAnExistingComposition() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.recordCandidateClick(at: start.addingTimeInterval(0.1)) == false)
        activity.didReadSnapshot(.unknown, hasPendingDraft: true, at: start.addingTimeInterval(0.2))
        #expect(activity.recordCandidateClick(at: start.addingTimeInterval(20)) == true)
        #expect(activity.lastTypingAt == start.addingTimeInterval(20))
        #expect(activity.recordCandidateClick(at: start.addingTimeInterval(51)) == false)
    }

    @Test func aNewKeyboardEventCanAssociateAFreshNativeComposition() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start.addingTimeInterval(0.1))
        activity.recordKeyboard(at: start.addingTimeInterval(31))
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start.addingTimeInterval(31.1))
        #expect(activity.hasActiveComposition(at: start.addingTimeInterval(32)))
        #expect(activity.markingEnded(at: start.addingTimeInterval(33)) == true)
        activity.recordKeyboard(at: start.addingTimeInterval(34))
        #expect(activity.markingEnded(at: start.addingTimeInterval(35)) == true)
    }

    @Test func staleSnapshotExpiredThenPlainUnknownDoesNotExtendThirtySeconds() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        activity.didReadSnapshot(.marked, hasPendingDraft: false, at: start.addingTimeInterval(0.1))
        activity.expire(at: start.addingTimeInterval(31))
        #expect(!activity.lastSnapshotWasMarked)
        activity.recordKeyboard(at: start.addingTimeInterval(32))
        activity.didReadSnapshot(.unknown, hasPendingDraft: false, at: start.addingTimeInterval(32.1))
        #expect(!activity.hasActiveComposition(at: start.addingTimeInterval(32.2)))
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(34)))
    }

    @Test func verifiedNotMarkedMetadataOverridesAStaleBegin() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.1)) == true)
        activity.didReadSnapshot(.notMarked, hasPendingDraft: false, at: start.addingTimeInterval(0.2))
        #expect(!activity.lastSnapshotWasMarked)
        #expect(!activity.overridesUnknownAsMarked(at: start.addingTimeInterval(0.3)))
        #expect(!activity.hasActiveComposition(at: start.addingTimeInterval(0.3)))
    }

    @Test func changingFieldOrPausingRejectsOldSessionNotifications() {
        var activity = InputCompositionActivity()
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.1)) == true)
        activity.reset()
        #expect(activity.markingEnded(at: start.addingTimeInterval(0.2)) == false)
        #expect(activity.markingBegan(fromApplication: true, at: start.addingTimeInterval(0.2)) == false)
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(0.2)))
    }

    @Test func endingBeforeTheAXValueChangesDoesNotChargePinyin() {
        var activity = InputCompositionActivity()
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        activity.recordKeyboard(at: start)
        #expect(activity.markingBegan(fromApplication: false, at: start.addingTimeInterval(0.1)) == true)
        #expect(input.observe(text: "nihao", composition: .marked, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        activity.didReadSnapshot(.unknown, hasPendingDraft: false, at: start.addingTimeInterval(0.2))
        #expect(activity.markingEnded(at: start.addingTimeInterval(0.3)) == true)
        let afterEnd = start.addingTimeInterval(0.4)
        #expect(!activity.overridesUnknownAsMarked(at: afterEnd))
        #expect(input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: activity.allowsTextRead(at: afterEnd), deferUnverifiedLatin: true) == 0)
        activity.didReadSnapshot(.unknown, hasPendingDraft: input.hasPendingVisibleText, at: afterEnd)
        #expect(input.observe(text: "你好", composition: .unknown, sameField: true, allowCounting: activity.allowsTextRead(at: start.addingTimeInterval(0.5)), deferUnverifiedLatin: true) == 2)
    }

    @Test func unsolicitedChangeInvalidationDoesNotChargeItToTheNextKey() {
        var activity = InputCompositionActivity()
        var input = TextInputAccumulator()
        _ = input.observe(text: "old", composition: .committed, sameField: false, allowCounting: false)
        activity.recordKeyboard(at: start)
        #expect(!activity.allowsTextRead(at: start.addingTimeInterval(3)))
        // This is the inactive ValueChanged branch: invalidate without reading.
        input.reset()
        activity.reset()
        activity.recordKeyboard(at: start.addingTimeInterval(4))
        #expect(input.observe(text: "script replaced the documentX", composition: .committed, sameField: true, allowCounting: true) == 0)
        #expect(input.observe(text: "script replaced the documentXY", composition: .committed, sameField: true, allowCounting: true) == 1)
    }
}

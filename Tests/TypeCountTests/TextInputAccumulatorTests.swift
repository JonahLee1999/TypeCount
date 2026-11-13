import Testing
@testable import TypeCount

struct TextInputAccumulatorTests {
    @Test func existingDocumentAndNewFocusDoNotCount() {
        var input = TextInputAccumulator()
        #expect(input.observe(text: "existing document", composition: .committed, sameField: false, allowCounting: true) == 0)
        #expect(input.observe(text: "another document", composition: .committed, sameField: false, allowCounting: true) == 0)
    }
    @Test func pinyinCompositionCountsOnlyTheCommit() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "draft ", composition: .committed, sameField: false, allowCounting: false)
        #expect(input.observe(text: "draft n", composition: .marked, sameField: true, allowCounting: true) == 0)
        #expect(input.observe(text: "draft nihao", composition: .marked, sameField: true, allowCounting: true) == 0)
        #expect(input.observe(text: "draft 你好", composition: .committed, sameField: true, allowCounting: true) == 2)
        #expect(input.observe(text: "draft 你好", composition: .committed, sameField: true, allowCounting: true) == 0)
    }
    @Test func cancelledCompositionAndDeletesDoNotIncrease() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "abc", composition: .committed, sameField: false, allowCounting: false)
        _ = input.observe(text: "abc ni", composition: .marked, sameField: true, allowCounting: true)
        #expect(input.observe(text: "abc", composition: .committed, sameField: true, allowCounting: true) == 0)
        #expect(input.observe(text: "ab", composition: .committed, sameField: true, allowCounting: true) == 0)
    }
    @Test func suppressedPasteUpdatesBaselineBeforeNextKeystroke() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false)
        #expect(input.observe(text: "a pasted paragraph", composition: .unknown, sameField: true, allowCounting: false) == 0)
        #expect(input.observe(text: "a pasted paragraph!", composition: .unknown, sameField: true, allowCounting: true) == 1)
    }

    @Test func unverifiedPinyinFramesCountOnlyTheChineseResult() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        for text in ["n", "ni", "nihao"] {
            #expect(input.observe(text: text, composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
            #expect(input.hasPendingVisibleText)
        }
        #expect(input.observe(text: "你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
        #expect(!input.hasPendingVisibleText)
        #expect(input.observe(text: "你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
    }

    @Test func cancelledUnverifiedPinyinDoesNotCount() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        _ = input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true)
        input.discardPending()
        #expect(!input.hasPendingVisibleText)
        #expect(input.commitPendingVisibleText() == 0)
        #expect(input.observe(text: "", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func newlyInsertedSpaceConfirmsEnglishOnlyOnce() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "hello", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "hello ", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 5)
        #expect(input.observe(text: "hello ", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.commitPendingVisibleText() == 0)
    }

    @Test func existingMixedPrefixCannotConfirmFollowingPinyin() {
        var input = TextInputAccumulator()
        let prefix = "ABC中文 "
        _ = input.observe(text: prefix, composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: prefix + "ni", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: prefix + "nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: prefix + "你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func existingSuffixSpaceDoesNotConfirmInsertedPinyin() {
        var input = TextInputAccumulator()
        _ = input.observe(text: " ", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "ni ", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "ni hao ", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "你好 ", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func newChinesePrefixDoesNotConfirmTheNextPinyinRun() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "你好shi", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
        #expect(input.observe(text: "你好世界", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func internalWhitespaceKeepsTheWholeLatinRunPending() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "hello n", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "hello nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "hello 你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 7)
    }

    @Test func pinyinSyllableSpacesDoNotCountBeforeChineseCommit() {
        for separator in [" ", "\u{00A0}", "\u{3000}"] {
            var input = TextInputAccumulator()
            _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
            #expect(input.observe(text: "ni\(separator)hao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
            #expect(input.hasPendingVisibleText)
            #expect(input.observe(text: "你好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
        }
    }

    @Test func cancellingSpacedPinyinDoesNotCountAnySyllable() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "ni hao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        input.discardPending()
        #expect(input.commitPendingVisibleText() == 0)
        #expect(input.observe(text: "", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
    }

    @Test func tonalLatinAndApostrophesStayPending() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "lǜ'shì", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "律师", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func sourceChangeDoesNotPromoteUnverifiedPreedit() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        _ = input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true)
        #expect(input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: true) == 0)
        #expect(input.commitPendingVisibleText() == 0)
        #expect(input.observe(text: "nihao!", composition: .unknown, sameField: true, allowCounting: true) == 1)
    }

    @Test func unchangedChineseInsideMultipleEditsCannotConfirmLatin() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "old中文suffix", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        #expect(input.observe(text: "ni中文hao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.hasPendingVisibleText)
        #expect(input.observe(text: "你中文好", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 2)
    }

    @Test func explicitCommitCountsPendingOnceAndRetypingRemainsCumulative() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        _ = input.observe(text: "hello", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true)
        #expect(input.commitPendingVisibleText() == 5)
        #expect(!input.hasPendingVisibleText)
        #expect(input.commitPendingVisibleText() == 0)
        #expect(input.observe(text: "", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.observe(text: "hello", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true) == 0)
        #expect(input.commitPendingVisibleText() == 5)
    }

    @Test func trustedCommitCanResolveUnknownPreedit() {
        var input = TextInputAccumulator()
        _ = input.observe(text: "", composition: .unknown, sameField: false, allowCounting: false, deferUnverifiedLatin: true)
        _ = input.observe(text: "nihao", composition: .unknown, sameField: true, allowCounting: true, deferUnverifiedLatin: true)
        #expect(input.observe(text: "你好", composition: .marked, sameField: true, allowCounting: true) == 0)
        #expect(input.commitPendingVisibleText() == 0)
        #expect(input.observe(text: "你好", composition: .committed, sameField: true, allowCounting: true) == 2)
    }
}

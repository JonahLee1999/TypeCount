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
}

import Testing
@testable import TypeCount

struct SystemInputSourceTests {
    @Test(arguments: [
        "com.apple.inputmethod.SCIM.ITABC",
        "com.apple.inputmethod.SCIM.Shuangpin"
    ])
    func recognizesSimplifiedPinyinModes(sourceID: String) {
        #expect(SystemInputSource.isSystemPinyin(sourceID: sourceID, bundleID: "com.apple.inputmethod.SCIM"))
    }

    @Test(arguments: [
        "com.apple.inputmethod.TCIM.Pinyin",
        "com.apple.inputmethod.TCIM.Shuangpin"
    ])
    func recognizesTraditionalPinyinModes(sourceID: String) {
        #expect(SystemInputSource.isSystemPinyin(sourceID: sourceID, bundleID: "com.apple.inputmethod.TCIM"))
    }

    @Test(arguments: [
        "com.apple.inputmethod.SCIM",
        "com.apple.inputmethod.SCIM.WBX",
        "com.apple.inputmethod.SCIM.WBH",
        "com.apple.keylayout.PinyinKeyboard",
        "com.apple.inputmethod.SCIM.ITABC.extra",
        "com.apple.inputmethod.SCIM.itabc"
    ])
    func doesNotInferPinyinFromSimplifiedChineseOrLayout(sourceID: String) {
        #expect(!SystemInputSource.isSystemPinyin(sourceID: sourceID, bundleID: "com.apple.inputmethod.SCIM"))
    }

    @Test(arguments: [
        "com.apple.inputmethod.TCIM",
        "com.apple.inputmethod.TCIM.Zhuyin",
        "com.apple.inputmethod.TCIM.ZhuyinEten",
        "com.apple.inputmethod.TCIM.Cangjie",
        "com.apple.inputmethod.TCIM.Jianyi",
        "com.apple.inputmethod.TCIM.WBH",
        "com.apple.keylayout.TraditionalPinyinKeyboard"
    ])
    func doesNotInferPinyinFromTraditionalChineseOrLayout(sourceID: String) {
        #expect(!SystemInputSource.isSystemPinyin(sourceID: sourceID, bundleID: "com.apple.inputmethod.TCIM"))
    }

    @Test func requiresTheMatchingAppleModeBundle() {
        let sourceID = "com.apple.inputmethod.SCIM.ITABC"
        for bundleID in [
            "im.rime.inputmethod.Squirrel",
            "com.sogou.inputmethod.sogou",
            "com.apple.inputmethod.TCIM",
            "com.apple.SCIM-Container",
            "com.apple.inputmethod.SCIM.extra",
            ""
        ] {
            #expect(!SystemInputSource.isSystemPinyin(sourceID: sourceID, bundleID: bundleID))
        }
        #expect(!SystemInputSource.isSystemPinyin(sourceID: "im.rime.inputmethod.Squirrel.Rime", bundleID: "im.rime.inputmethod.Squirrel"))
        #expect(!SystemInputSource.isSystemPinyin(sourceID: "com.sogou.inputmethod.sogou.pinyin", bundleID: "com.sogou.inputmethod.sogou"))
        #expect(!SystemInputSource.isSystemPinyin(sourceID: "com.apple.keylayout.ABC", bundleID: "com.apple.KeyboardLayouts"))
    }

    @Test func missingMetadataIsUnknown() {
        #expect(!SystemInputSource.isSystemPinyin(sourceID: nil, bundleID: nil))
        #expect(!SystemInputSource.isSystemPinyin(sourceID: nil, bundleID: "com.apple.inputmethod.SCIM"))
        #expect(!SystemInputSource.isSystemPinyin(sourceID: "com.apple.inputmethod.SCIM.ITABC", bundleID: nil))
        #expect(!SystemInputSource.isSystemPinyin(sourceID: "", bundleID: "com.apple.inputmethod.SCIM"))
    }
}

import XCTest
@testable import PopBarKit

final class TranslateLanguageTests: XCTestCase {
    let zhPrefs = LanguagePrefs(primary: "zh-CN", secondary: "en")

    func testDetectScripts() {
        let cases: [(String, String?)] = [
            ("我们今天开会讨论这个问题", "zh-CN"),
            ("我們今天開會討論這個問題", "zh-TW"),
            ("这个", "zh-CN"), ("這個", "zh-TW"),
            ("今日はいい天気ですね", "ja"),
            ("東京都知事選挙結果", "ja"),          // 纯汉字的日文
            ("経済産業省", "ja"),
            ("안녕하세요 반갑습니다", "ko"),
            ("Привет, как дела?", "ru"),
            ("Thank you very much", "en"),
            ("Je ne sais pas ce que tu veux dire", "fr"),
            ("Das ist ein schönes Haus", "de"),
            ("12345 + 678 = ?", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LanguageDetect.detect(text, prefs: zhPrefs), expected, text)
        }
    }

    func testMixedTextUsesMajority() {
        // 英文里夹一两个汉字仍是英语；中文里夹英文术语仍是中文
        XCTAssertEqual(LanguageDetect.detect("Use 微信 to log in to your account first", prefs: zhPrefs), "en")
        XCTAssertEqual(LanguageDetect.detect("请点击 Settings 按钮", prefs: zhPrefs), "zh-CN")
        XCTAssertEqual(LanguageDetect.detect("这个 API 怎么调用", prefs: zhPrefs), "zh-CN")
        // 中文里夹一个假名不算日文
        XCTAssertEqual(LanguageDetect.detect("我们今天下午开会讨论の问题", prefs: zhPrefs), "zh-CN")
    }

    func testShortLatinWordsDefaultToEnglish() {
        for w in ["cache", "message", "API", "OK", "Settings"] {
            XCTAssertEqual(LanguageDetect.detect(w, prefs: zhPrefs), "en", w)
        }
    }

    func testAmbiguousHanFollowsPrefs() {
        XCTAssertEqual(LanguageDetect.detect("你好", prefs: zhPrefs), "zh-CN")
        XCTAssertEqual(LanguageDetect.detect("你好", prefs: LanguagePrefs(primary: "zh-TW", secondary: "en")), "zh-TW")
    }

    func testPrefsResolve() {
        // 英文系统 + 中文作为第二系统语言：首选中文、第二英语
        XCTAssertEqual(LanguagePrefs.resolve(primary: "system", secondary: "auto", preferred: ["en-US", "zh-Hans-CN"]),
                       LanguagePrefs(primary: "zh-CN", secondary: "en"))
        XCTAssertEqual(LanguagePrefs.resolve(primary: "system", secondary: "auto", preferred: ["zh-Hant-TW"]),
                       LanguagePrefs(primary: "zh-TW", secondary: "en"))
        XCTAssertEqual(LanguagePrefs.resolve(primary: "system", secondary: "auto", preferred: ["ja-JP", "en-US"]),
                       LanguagePrefs(primary: "ja", secondary: "en"))
        // 只有英语：第二语言回落简体中文
        XCTAssertEqual(LanguagePrefs.resolve(primary: "system", secondary: "auto", preferred: ["en-GB"]),
                       LanguagePrefs(primary: "en", secondary: "zh-CN"))
        // 第二语言和首选同族时纠正
        XCTAssertEqual(LanguagePrefs.resolve(primary: "zh-CN", secondary: "zh-TW", preferred: []),
                       LanguagePrefs(primary: "zh-CN", secondary: "en"))
        XCTAssertEqual(LanguagePrefs.resolve(primary: "fr", secondary: "de", preferred: []),
                       LanguagePrefs(primary: "fr", secondary: "de"))
    }

    func testDirection() {
        func dir(_ s: String, _ t: String, _ text: String, _ p: LanguagePrefs? = nil) -> TranslateDirection {
            TranslateDirection.resolve(source: s, target: t, text: text, prefs: p ?? zhPrefs)
        }
        XCTAssertEqual(dir("auto", "auto", "Hello world, how are you").target, "zh-CN")
        XCTAssertEqual(dir("auto", "auto", "你好世界").target, "en")
        XCTAssertEqual(dir("auto", "auto", "今日はいい天気ですね").target, "zh-CN")
        XCTAssertEqual(dir("auto", "auto", "Use 微信 to log in to your account first").target, "zh-CN")
        // 繁体原文对简体首选用户 → 译成第二语言
        XCTAssertEqual(dir("auto", "auto", "我們今天開會討論這個問題").target, "en")
        // 手动源语言优先于文本内容
        XCTAssertEqual(dir("en", "auto", "Use 微信登录").target, "zh-CN")
        // 手动目标和识别出的原文同语言 → 改译另一个偏好语言
        XCTAssertEqual(dir("auto", "ja", "今日はいい天気ですね").target, "zh-CN")
        // 手动简繁互转是合法需求
        XCTAssertEqual(dir("auto", "zh-CN", "我們今天開會討論這個問題").target, "zh-CN")
        // 英语为首选的用户
        let enPrefs = LanguagePrefs(primary: "en", secondary: "zh-CN")
        XCTAssertEqual(dir("auto", "auto", "Hello world, how are you", enPrefs).target, "zh-CN")
        XCTAssertEqual(dir("auto", "auto", "Je ne sais pas ce que tu veux dire", enPrefs).target, "en")
        // 没有文字 → 首选语言
        XCTAssertEqual(dir("auto", "auto", "12345").target, "zh-CN")
    }

    func testPromptSafetyNet() {
        let d = TranslateDirection.resolve(source: "auto", target: "auto", text: "Hello world, how are you", prefs: zhPrefs)
        let p = TranslatePrompt.systemPrompt(d)
        XCTAssertTrue(p.contains("into Simplified Chinese."))
        XCTAssertTrue(p.contains("If the text is already in Simplified Chinese, translate it into English instead."))
        let manual = TranslateDirection.resolve(source: "en", target: "auto", text: "Hello", prefs: zhPrefs)
        XCTAssertTrue(TranslatePrompt.systemPrompt(manual).contains("The source language is English."))
        XCTAssertFalse(TranslatePrompt.systemPrompt(manual).contains("already in"))
    }

    func testTemplateRender() {
        let d = TranslateDirection(source: "auto", from: "ja", target: "zh-CN", alternate: "en")
        XCTAssertEqual(TranslatePrompt.render("{$query.detectFromLang}→$query.detectToLang: {$query.text}", text: "x", direction: d),
                       "Japanese→Simplified Chinese: x")
    }
}

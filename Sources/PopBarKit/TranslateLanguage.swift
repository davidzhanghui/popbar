import Foundation
import NaturalLanguage
import AVFoundation
import PopBarCore

// MARK: - 支持的语言

/// 翻译支持的语言表：配置代码、提示词里的英文名、界面标题、NL 识别枚举、朗读语言，统一从这里取
struct TranslateLanguage: Equatable {
    let code: String
    let promptName: String
    let zhTitle: String
    let enTitle: String
    let nl: NLLanguage
    let voice: String

    var title: String { L10n.t(zhTitle, enTitle) }

    static let all: [TranslateLanguage] = [
        .init(code: "zh-CN", promptName: "Simplified Chinese", zhTitle: "简体中文", enTitle: "Chinese (Simplified)", nl: .simplifiedChinese, voice: "zh-CN"),
        .init(code: "zh-TW", promptName: "Traditional Chinese", zhTitle: "繁體中文", enTitle: "Chinese (Traditional)", nl: .traditionalChinese, voice: "zh-TW"),
        .init(code: "en", promptName: "English", zhTitle: "英语", enTitle: "English", nl: .english, voice: "en-US"),
        .init(code: "ja", promptName: "Japanese", zhTitle: "日语", enTitle: "Japanese", nl: .japanese, voice: "ja-JP"),
        .init(code: "ko", promptName: "Korean", zhTitle: "韩语", enTitle: "Korean", nl: .korean, voice: "ko-KR"),
        .init(code: "fr", promptName: "French", zhTitle: "法语", enTitle: "French", nl: .french, voice: "fr-FR"),
        .init(code: "de", promptName: "German", zhTitle: "德语", enTitle: "German", nl: .german, voice: "de-DE"),
        .init(code: "es", promptName: "Spanish", zhTitle: "西班牙语", enTitle: "Spanish", nl: .spanish, voice: "es-ES"),
        .init(code: "pt", promptName: "Portuguese", zhTitle: "葡萄牙语", enTitle: "Portuguese", nl: .portuguese, voice: "pt-BR"),
        .init(code: "it", promptName: "Italian", zhTitle: "意大利语", enTitle: "Italian", nl: .italian, voice: "it-IT"),
        .init(code: "ru", promptName: "Russian", zhTitle: "俄语", enTitle: "Russian", nl: .russian, voice: "ru-RU"),
        .init(code: "vi", promptName: "Vietnamese", zhTitle: "越南语", enTitle: "Vietnamese", nl: .vietnamese, voice: "vi-VN"),
    ]

    /// 用拉丁字母书写、需要靠 NL 区分的语言
    static let latinCodes = ["en", "fr", "de", "es", "pt", "it", "vi"]

    static func find(_ code: String) -> TranslateLanguage? {
        all.first { $0.code == code } ?? (code == "zh" ? all[0] : nil)
    }

    static func title(_ code: String) -> String { find(code)?.title ?? code }
    static func promptName(_ code: String) -> String { find(code)?.promptName ?? code }

    /// 选择器选项；extra 放在最前（如「自动」「跟随系统」）
    static func options(_ extra: [(String, String)] = []) -> [(String, String)] {
        extra + all.map { ($0.code, $0.title) }
    }

    /// 简繁中文算同一种语言（自动目标语言时用）
    static func family(_ code: String) -> String { code.hasPrefix("zh") ? "zh" : code }

    /// 系统语言标识（BCP 47，如 zh-Hans-CN / zh-Hant-TW / en-US）→ 支持的语言代码
    static func match(locale identifier: String) -> String? {
        let id = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if id.hasPrefix("zh") {
            let traditional = id.contains("hant") || id.hasSuffix("-tw") || id.hasSuffix("-hk") || id.hasSuffix("-mo")
            return traditional ? "zh-TW" : "zh-CN"
        }
        let base = String(id.split(separator: "-").first ?? "")
        return all.first { $0.code == base }?.code
    }
}

// MARK: - 首选语言 / 第二语言

/// 自动目标语言的依据：原文是首选语言 → 译成第二语言；否则 → 译成首选语言
struct LanguagePrefs: Equatable {
    let primary: String
    let secondary: String

    static var current: LanguagePrefs {
        let c = ConfigStore.shared.config
        return resolve(primary: c.primaryLanguage, secondary: c.secondaryLanguage)
    }

    /// primary: "system" 或语言代码；secondary: "auto" 或语言代码
    /// 跟随系统时优先取系统语言列表里第一个非英语的语言（英语常是装机默认的「外语」），都没有就英语
    static func resolve(primary: String, secondary: String,
                        preferred: [String] = Locale.preferredLanguages) -> LanguagePrefs {
        let system = preferred.compactMap { TranslateLanguage.match(locale: $0) }
        let p: String
        if primary != "system", TranslateLanguage.find(primary) != nil {
            p = primary
        } else {
            p = system.first { $0 != "en" } ?? system.first ?? "zh-CN"
        }
        func fallback() -> String {
            if p != "en" { return "en" }
            return system.first { TranslateLanguage.family($0) != "en" } ?? "zh-CN"
        }
        var s = secondary == "auto" ? fallback() : secondary
        if TranslateLanguage.find(s) == nil || TranslateLanguage.family(s) == TranslateLanguage.family(p) {
            s = fallback()
        }
        return LanguagePrefs(primary: p, secondary: s)
    }

    /// 和 lang 不同的那一个：lang 是首选语言 → 第二语言，否则 → 首选语言
    func other(than lang: String) -> String {
        TranslateLanguage.family(lang) == TranslateLanguage.family(primary) ? secondary : primary
    }
}

// MARK: - 语言识别

/// 规则 + NaturalLanguage 的本地语言识别（离线、毫秒级）：
/// 1. 按文字系统计数，按「占多数」而不是「出现过」判断，一个汉字/假名/谚文约等于 3 个字母
/// 2. 假名、谚文直接定日文/韩文；纯汉字用 NL 区分日文，用 ICU 简繁转换区分简体/繁体
/// 3. 拉丁字母用 NL 在支持的语言里判断；短文本置信度不够就当英语
enum LanguageDetect {
    struct ScriptCounts: Equatable {
        var han = 0, kana = 0, hangul = 0, latin = 0, cyrillic = 0
        var eastAsian: Int { han + kana + hangul }
    }

    static func counts(_ text: String) -> ScriptCounts {
        var c = ScriptCounts()
        for s in text.unicodeScalars {
            switch s.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: c.han += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF: c.kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: c.hangul += 1
            case 0x0400...0x04FF: c.cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: c.latin += 1
            default: break
            }
        }
        return c
    }

    /// 识别语言代码；没有任何文字（纯数字、符号）返回 nil
    static func detect(_ text: String, prefs: LanguagePrefs? = nil) -> String? {
        let sample = String(text.prefix(2000))
        let c = counts(sample)
        let alphabetic = c.latin + c.cyrillic
        guard c.eastAsian + alphabetic > 0 else { return nil }

        if c.eastAsian * 3 >= alphabetic {
            if c.hangul > c.han + c.kana { return "ko" }
            if c.kana > 0 && c.kana * 5 >= c.han { return "ja" }
            if c.han == 0 { return c.kana > 0 ? "ja" : "ko" }
            return hanLanguage(sample, prefs: prefs)
        }
        if c.cyrillic > c.latin { return "ru" }
        return latinLanguage(sample, letters: c.latin, prefs: prefs)
    }

    /// 纯汉字（或汉字为主）：先看是不是日文汉字，再按简繁转换前后差异分简体/繁体
    static func hanLanguage(_ text: String, prefs: LanguagePrefs? = nil) -> String {
        let hyps = hypotheses(text, among: [.simplifiedChinese, .traditionalChinese, .japanese])
        if (hyps[.japanese] ?? 0) >= 0.9 { return "ja" }
        let traditional = changedCount(text, "Hant-Hans")
        let simplified = changedCount(text, "Hans-Hant")
        if traditional > simplified { return "zh-TW" }
        if simplified > traditional { return "zh-CN" }
        // 简繁同形（「你好」「中文」）：跟用户偏好走
        return prefs?.primary == "zh-TW" || prefs?.secondary == "zh-TW" ? "zh-TW" : "zh-CN"
    }

    static func latinLanguage(_ text: String, letters: Int, prefs: LanguagePrefs? = nil) -> String {
        let candidates = TranslateLanguage.latinCodes.compactMap { TranslateLanguage.find($0)?.nl }
        // languageHints 里没列出的语言先验会被压到 0，所以每个候选都给个底，英语和用户偏好语言再加权
        var hints = Dictionary(uniqueKeysWithValues: candidates.map { ($0, 0.1) })
        hints[.english] = 0.5
        for code in [prefs?.primary, prefs?.secondary].compactMap({ $0 }) where TranslateLanguage.latinCodes.contains(code) {
            if let nl = TranslateLanguage.find(code)?.nl { hints[nl] = max(hints[nl] ?? 0, 0.3) }
        }
        let hyps = hypotheses(text, among: candidates, hints: hints)
        guard let best = hyps.max(by: { $0.value < $1.value }) else { return "en" }
        // 「cache」「message」这种短词 NL 常判成法语，短文本要求更高置信度
        let threshold = letters < 16 ? 0.65 : 0.5
        guard best.value >= threshold,
              let code = TranslateLanguage.all.first(where: { $0.nl == best.key })?.code else { return "en" }
        return code
    }

    private static func hypotheses(_ text: String, among langs: [NLLanguage],
                                   hints: [NLLanguage: Double] = [:]) -> [NLLanguage: Double] {
        let r = NLLanguageRecognizer()
        r.languageConstraints = langs
        r.languageHints = hints
        r.processString(text)
        return r.languageHypotheses(withMaximum: langs.count)
    }

    /// 经过简繁转换后变了的字数（Hant-Hans：繁体字数；Hans-Hant：简体字数）
    private static func changedCount(_ text: String, _ transform: String) -> Int {
        guard let out = text.applyingTransform(StringTransform(transform), reverse: false) else { return 0 }
        return zip(text.unicodeScalars, out.unicodeScalars).filter { $0 != $1 }.count
    }

    /// 朗读用的语言：识别不出、或和系统默认音色同语言时返回 nil（用系统默认音色）
    static func voiceLanguage(_ text: String) -> String? {
        guard let code = detect(text, prefs: LanguagePrefs.current),
              let voice = TranslateLanguage.find(code)?.voice else { return nil }
        let current = TranslateLanguage.match(locale: AVSpeechSynthesisVoice.currentLanguageCode())
        return current == code ? nil : voice
    }
}

// MARK: - 翻译方向

/// 一次翻译的方向：源语言（手动或识别结果）、目标语言，以及「原文已经是目标语言」时的退路
struct TranslateDirection: Equatable {
    /// 用户选的源语言（"auto" 或代码）
    let source: String
    /// 实际源语言：手动选的，或识别结果（可能为 nil）
    let from: String?
    let target: String
    /// 原文已经是目标语言时改译成的语言
    let alternate: String

    static func resolve(source: String, target: String, text: String,
                        prefs: LanguagePrefs = .current) -> TranslateDirection {
        let from = source != "auto" ? source : LanguageDetect.detect(text, prefs: prefs)
        let to: String
        if target != "auto" {
            // 手动目标语言；自动识别出的源语言恰好相同（如日文原文 → 日语）时改译成另一个偏好语言
            if source == "auto", let from, from == target {
                to = prefs.other(than: from)
            } else {
                to = target
            }
        } else if let from {
            to = prefs.other(than: from)
        } else {
            to = prefs.primary
        }
        return TranslateDirection(source: source, from: from, target: to, alternate: prefs.other(than: to))
    }
}

// MARK: - 提示词

enum TranslatePrompt {
    static func languageName(_ code: String) -> String { TranslateLanguage.promptName(code) }

    static func systemPrompt(_ d: TranslateDirection) -> String {
        var lines = [
            "You are a professional translation engine.",
            "Translate the user's text into \(languageName(d.target)).",
            "Output only the translation itself: no explanations, no notes, no surrounding quotes.",
            "Preserve the original formatting, line breaks, numbers, code snippets and proper nouns.",
        ]
        if d.source != "auto" {
            lines.append("The source language is \(languageName(d.source)).")
        } else if d.alternate != d.target {
            // 本地识别可能出错：原文已经是目标语言时让模型自己改译成另一个偏好语言
            lines.append("If the text is already in \(languageName(d.target)), translate it into \(languageName(d.alternate)) instead.")
        }
        return lines.joined(separator: " ")
    }

    /// 开启「自定义提示词」时系统提示词的默认模板(用变量保留动态目标语言)
    static let customSystemTemplate =
        "You are a professional translation engine. Translate the user's text into {$query.detectToLang}. Output only the translation itself: no explanations, no notes, no surrounding quotes. Preserve the original formatting, line breaks, numbers, code snippets and proper nouns."

    /// 模板变量替换,带不带花括号都认:
    /// {$query.text} / $query.text 原文、{$query.detectFromLang} / $query.detectFromLang 源语言、
    /// {$query.detectToLang} / $query.detectToLang 目标语言
    static func render(_ template: String, text: String, direction d: TranslateDirection) -> String {
        let from = d.from.map(languageName) ?? "the source language"
        let to = languageName(d.target)
        // 先替换带花括号的,再替换裸写法(后者是前者的子串,顺序不能反)
        return template
            .replacingOccurrences(of: "{$query.text}", with: text)
            .replacingOccurrences(of: "{$query.detectFromLang}", with: from)
            .replacingOccurrences(of: "{$query.detectToLang}", with: to)
            .replacingOccurrences(of: "$query.text", with: text)
            .replacingOccurrences(of: "$query.detectFromLang", with: from)
            .replacingOccurrences(of: "$query.detectToLang", with: to)
    }

    /// 组装发给模型的 (system, user):provider 配了自定义提示词就渲染模板,否则用默认翻译提示词
    static func messages(_ d: TranslateDirection, text: String,
                         provider: LLMProvider) -> (system: String?, user: String) {
        let system = provider.systemPrompt.map {
            render($0, text: text, direction: d)
        } ?? systemPrompt(d)
        let user = provider.userPrompt.map {
            render($0.isEmpty ? "{$query.text}" : $0, text: text, direction: d)
        } ?? text
        return (system, user)
    }
}

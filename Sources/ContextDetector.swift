import Cocoa
import Foundation

/// 选中内容的上下文识别:全部纯函数,供工具条动态追加按钮。
/// M3 在 URL/邮箱/算式之外扩展时间戳、JSON、Base64、URL 编码、颜色、
/// 文件路径、电话、地址、日期、数字+币种/单位等;上限 3 个上下文按钮。
enum ContextDetector {
    /// 文本过长时跳过识别(性能上限)
    static let maxLength = 2000

    enum Kind: Equatable {
        case url(String)
        case email(String)
        case calc(String)
        /// Unix 时间戳(秒或毫秒),附带解析出的 Date
        case timestamp(Date)
        /// 合法 JSON(对象或数组)
        case json
        /// Base64(可解码出可读文本或能编码)
        case base64
        /// URL 编码(含 %XX)
        case urlEncoded
        /// 颜色:HEX/RGB()/HSL()
        case color(NSColor)
        /// 本地文件路径(存在即可)
        case filePath(String)
        /// 电话号码
        case phone(String)
        /// 地址(NSDataDetector)
        case address(String)
        /// 含日期时间的文本(NSDataDetector)
        case date(Date)
        /// 数字 + 币种(如 "¥128"、"$20"、"128 CNY")
        case money(amount: Double, currency: String)
        /// 数字 + 常见单位(如 "5 miles"、"80kg"、"72°F")
        case unit(amount: Double, unit: String)
    }

    /// 返回当前文本可识别的全部上下文(可能有多个,调用方取前 3 个)
    static func detect(_ text: String) -> [Kind] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxLength else { return [] }
        var kinds: [Kind] = []
        if isURLLike(t) { kinds.append(.url(t)) }
        if isEmail(t) { kinds.append(.email(t)) }
        if let r = evaluate(t) { kinds.append(.calc(r)) }
        if let d = asTimestamp(t) { kinds.append(.timestamp(d)) }
        if isJSON(t) { kinds.append(.json) }
        if let c = asColor(t) { kinds.append(.color(c)) }
        if let p = asFilePath(t) { kinds.append(.filePath(p)) }
        if isBase64(t) { kinds.append(.base64) }
        if isURLEncoded(t) { kinds.append(.urlEncoded) }
        if let m = asMoney(t) { kinds.append(.money(amount: m.0, currency: m.1)) }
        if let u = asUnit(t) { kinds.append(.unit(amount: u.0, unit: u.1)) }
        dataDetect(t).forEach { kinds.append($0) }
        return kinds
    }

    // MARK: - 已有识别

    static func isURLLike(_ s: String) -> Bool {
        s.range(of: "^(https?://|www\\.)\\S+$", options: [.regularExpression, .caseInsensitive]) != nil
            || s.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/\\S*)?$",
                       options: [.regularExpression, .caseInsensitive]) != nil
            || s.range(of: "^(mailto:|ftp://|ssh://|git@)\\S+$",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    /// 四则运算表达式求值;合法且有限返回格式化结果
    static func evaluate(_ s: String) -> String? {
        guard s.count <= 200,
              s.range(of: "^[0-9+\\-*/().%\\s]+$", options: .regularExpression) != nil,
              s.range(of: "[+\\-*/]", options: .regularExpression) != nil,
              s.range(of: "\\d", options: .regularExpression) != nil else { return nil }
        var p = ExprParser(s)
        guard let d = p.parse(), d.isFinite else { return nil }
        return d == d.rounded() && abs(d) < 1e15
            ? String(format: "%.0f", d)
            : String(format: "%g", d)
    }

    // MARK: - M3 新识别

    /// Unix 时间戳:10 位秒或 13 位毫秒,年份限定 2000–2100 避免误命中普通数字
    static func asTimestamp(_ s: String) -> Date? {
        guard s.range(of: "^\\d{10}(\\d{3})?$", options: .regularExpression) != nil else { return nil }
        guard let n = Double(s) else { return nil }
        let d = s.count == 13 ? Date(timeIntervalSince1970: n / 1000)
                              : Date(timeIntervalSince1970: n)
        let year = Calendar.current.component(.year, from: d)
        guard (2000...2100).contains(year) else { return nil }
        return d
    }

    static func isJSON(_ s: String) -> Bool {
        guard s.hasPrefix("{") || s.hasPrefix("[") else { return false }
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Base64:解码后若是可读文本则判定成功;字母数字+/= 组合,长度 ≥ 8
    static func isBase64(_ s: String) -> Bool {
        guard s.count >= 8, s.count <= maxLength,
              s.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
              let data = Data(base64Encoded: s) else { return false }
        guard let decoded = String(data: data, encoding: .utf8) else { return false }
        // 解码结果大部分是可见字符才算「可解码」
        let printable = decoded.filter { !$0.isNewline && !$0.isASCII ? true : ($0.isASCII) }
        return printable.count >= decoded.count / 2 && !decoded.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
    }

    static func isURLEncoded(_ s: String) -> Bool {
        s.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
            && s.removingPercentEncoding != s
    }

    /// 颜色: #RGB/#RRGGBB/#RRGGBBAA、rgb(r,g,b)、rgba(...)、hsl(h,s%,l%)
    static func asColor(_ s: String) -> NSColor? {
        if let m = s.range(of: "^#([0-9A-Fa-f]{3,8})$", options: .regularExpression),
           let c = hexColor(String(s[m].dropFirst())) { return c }
        if let g = s.range(of: "^rgba?\\(\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*(,\\s*[0-9.]+\\s*)?\\)$",
                           options: [.regularExpression, .caseInsensitive]) {
            let nums = String(s[g]).components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Double($0) }
            if nums.count >= 3 {
                return NSColor(srgbRed: min(1, nums[0] / 255), green: min(1, nums[1] / 255),
                               blue: min(1, nums[2] / 255), alpha: nums.count > 3 ? min(1, nums[3]) : 1)
            }
        }
        if let g = s.range(of: "^hsl\\(\\s*([0-9.]+)\\s*,\\s*([0-9.]+)%?\\s*,\\s*([0-9.]+)%?\\s*\\)$",
                           options: [.regularExpression, .caseInsensitive]) {
            let nums = String(s[g]).components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .compactMap { Double($0) }
            if nums.count == 3 {
                return NSColor(hue: nums[0].truncatingRemainder(dividingBy: 360) / 360,
                               saturation: min(1, nums[1] / 100),
                               brightness: min(1, nums[2] / 100), alpha: 1)
            }
        }
        return nil
    }

    static func hexColor(_ hex: String) -> NSColor? {
        var h = hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8,
              let v = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((v >> (h.count == 8 ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (h.count == 8 ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (h.count == 8 ? 8 : 0)) & 0xFF) / 255
        let a = h.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// 文件路径:展开 ~,要求真实存在且是文件/目录
    static func asFilePath(_ s: String) -> String? {
        guard s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../"),
              !s.contains("\n"), s.count <= 500 else { return nil }
        let expanded = NSString(string: s).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    static func isBase64DecodableText(_ s: String) -> Bool { isBase64(s) }

    /// 数字 + 币种:¥/￥/$/€/£ 前缀 或 三位币种代码后缀/前缀
    static func asMoney(_ s: String) -> (Double, String)? {
        let map: [String: String] = ["¥": "CNY", "￥": "CNY", "$": "USD",
                                     "€": "EUR", "£": "GBP", "HK$": "HKD"]
        for (sym, code) in map {
            if s.hasPrefix(sym) {
                let num = s.dropFirst(sym.count).replacingOccurrences(of: ",", with: "")
                if let v = Double(num.trimmingCharacters(in: .whitespaces)) { return (v, code) }
            }
        }
        if let m = s.range(of: "^([0-9,.]+)\\s*(USD|CNY|EUR|JPY|GBP|HKD|RMB)$",
                           options: [.regularExpression, .caseInsensitive]) {
            let parts = String(s[m]).components(separatedBy: .whitespaces)
            if let v = Double(parts.first?.replacingOccurrences(of: ",", with: "") ?? "") {
                return (v, parts.last?.uppercased() ?? "")
            }
        }
        if let m = s.range(of: "^(USD|CNY|EUR|JPY|GBP|HKD|RMB)\\s*([0-9,.]+)$",
                           options: [.regularExpression, .caseInsensitive]) {
            let t = String(s[m])
            let code = t.components(separatedBy: CharacterSet.letters.inverted)
                .first.map { $0 } ?? ""
            let numStr = t.components(separatedBy: CharacterSet.decimalDigits.union(.punctuationCharacters).inverted)
                .first ?? ""
            if let v = Double(numStr.replacingOccurrences(of: ",", with: "")) {
                let c = t.prefix { $0.isLetter }.uppercased()
                _ = code
                return (v, String(c))
            }
        }
        return nil
    }

    /// 数字 + 常见单位;返回 (数值, 规范单位名)
    static func asUnit(_ s: String) -> (Double, String)? {
        guard let m = s.range(
            of: "^(-?[0-9.,]+)\\s*(cms?|mms?|kms?|ms?|inches|inch|ins?|ft|feet|miles?|mi|kgs?|gs?|lbs?|oz|mls?|ls?|mbs?|gbs?|kbs?|tbs?|°c|°f|c|f)$",
            options: [.regularExpression, .caseInsensitive]) else { return nil }
        let t = String(s[m])
        let numStr = t.components(separatedBy: CharacterSet.decimalDigits.union([".", "-", ","]).inverted)
            .first ?? ""
        guard let v = Double(numStr.replacingOccurrences(of: ",", with: "")) else { return nil }
        var unit = t.dropFirst(numStr.count).trimmingCharacters(in: .whitespaces).lowercased()
        // 排除纯数字字母没有单位的情况已由正则保证;排除 "5m" 误命中 "million" 场景靠单位白名单
        guard !unit.isEmpty else { return nil }
        // 复数规范化:miles→mile、inches→inch、kgs→kg
        if unit == "inches" { unit = "inch" }
        else if unit.hasSuffix("s"), unit != "ms",
                ["cm","mm","km","m","in","mile","kg","g","lb","ml","l","mb","gb","kb","tb"]
                    .contains(String(unit.dropLast())) {
            unit = String(unit.dropLast())
        }
        return (v, unit)
    }

    /// NSDataDetector:电话、地址、日期;各取第一个命中
    static func dataDetect(_ s: String) -> [Kind] {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address, .date, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        var out: [Kind] = []
        var hasPhone = false, hasAddr = false, hasDate = false
        let full = NSRange(s.startIndex..<s.endIndex, in: s)
        for m in detector.matches(in: s, range: full) {
            guard let r = Range(m.range, in: s), r.lowerBound == s.startIndex,
                  r.upperBound == s.endIndex else { continue }   // 只认整段匹配,避免误判
            switch m.resultType {
            case .phoneNumber where !hasPhone && m.phoneNumber != nil:
                hasPhone = true; out.append(.phone(m.phoneNumber!))
            case .address where !hasAddr:
                hasAddr = true; out.append(.address(s))
            case .date where !hasDate && m.date != nil:
                hasDate = true; out.append(.date(m.date!))
            default: break
            }
        }
        return out
    }
}

/// 四则运算解析器(替代 NSExpression,避免 "1/0" 这类输入抛 ObjC 异常)
struct ExprParser {
    private let s: [Character]
    private var i = 0

    init(_ str: String) { s = Array(str) }

    mutating func parse() -> Double? {
        guard let v = expr() else { return nil }
        ws()
        return i == s.count ? v : nil
    }

    private mutating func ws() {
        while i < s.count && s[i] == " " { i += 1 }
    }

    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while true {
            ws()
            guard i < s.count, s[i] == "+" || s[i] == "-" else { return v }
            let add = s[i] == "+"
            i += 1
            guard let r = term() else { return nil }
            v = add ? v + r : v - r
        }
    }

    private mutating func term() -> Double? {
        guard var v = factor() else { return nil }
        while true {
            ws()
            guard i < s.count, s[i] == "*" || s[i] == "/" || s[i] == "%" else { return v }
            let op = s[i]
            i += 1
            guard let r = factor() else { return nil }
            switch op {
            case "*": v *= r
            case "/": if r == 0 { return nil }; v /= r
            default:  if r == 0 { return nil }; v = v.truncatingRemainder(dividingBy: r)
            }
        }
    }

    private mutating func factor() -> Double? {
        ws()
        guard i < s.count else { return nil }
        let c = s[i]
        if c == "-" { i += 1; return factor().map { -$0 } }
        if c == "+" { i += 1; return factor() }
        if c == "(" {
            i += 1
            guard let v = expr() else { return nil }
            ws()
            guard i < s.count, s[i] == ")" else { return nil }
            i += 1
            return v
        }
        var j = i, hasDot = false
        while j < s.count {
            if s[j].isNumber { j += 1 }
            else if s[j] == "." && !hasDot { hasDot = true; j += 1 }
            else { break }
        }
        guard j > i else { return nil }
        let num = Double(String(s[i..<j]))
        i = j
        return num
    }
}

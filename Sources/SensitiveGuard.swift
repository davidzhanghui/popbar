import Cocoa

/// #16 敏感信息检测:手机号/身份证/银行卡/邮箱/API Key/私钥/内网 IP。
/// 全部本地正则与校验,不联网、不写日志。
enum SensitiveDetector {
    enum Kind: String, CaseIterable {
        case phone, idcard, bankcard, email, apikey, privatekey, internalip

        var displayName: String {
            switch self {
            case .phone: return L10n.t("手机号", "phone number")
            case .idcard: return L10n.t("身份证", "ID number")
            case .bankcard: return L10n.t("银行卡", "bank card")
            case .email: return L10n.t("邮箱", "email")
            case .apikey: return L10n.t("API Key/Token", "API key/token")
            case .privatekey: return L10n.t("私钥", "private key")
            case .internalip: return L10n.t("内网 IP", "internal IP")
            }
        }
    }

    struct Hit {
        let kind: Kind
        let range: NSRange          // in UTF-16(NSString)坐标
        let masked: String          // 打码形态,如 138****5678
    }

    static func detect(_ text: String, types: Set<Kind>) -> [Hit] {
        var hits: [Hit] = []
        let ns = text as NSString
        for kind in Kind.allCases where types.contains(kind) {
            hits += scan(kind, in: ns)
        }
        return hits.sorted { $0.range.location < $1.range.location }
    }

    /// 就地脱敏:把命中片段替换成 masked 形态
    static func mask(_ text: String, hits: [Hit]) -> String {
        let ns = NSMutableString(string: text)
        for h in hits.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: h.range, with: h.masked)
        }
        return ns as String
    }

    /// 可还原脱敏:命中片段换成占位符 ⟦KIND_n⟧,返回映射用于结果还原
    static func placeholders(_ text: String, hits: [Hit]) -> (String, [String: String]) {
        let ns = NSMutableString(string: text)
        var map: [String: String] = [:]
        var counts: [Kind: Int] = [:]
        for h in hits.sorted(by: { $0.range.location > $1.range.location }) {
            counts[h.kind, default: 0] += 1
            let token = "⟦\(h.kind.rawValue.uppercased())_\(counts[h.kind]!)⟧"
            map[token] = (ns as NSString).substring(with: h.range)
            ns.replaceCharacters(in: h.range, with: token)
        }
        return (ns as String, map)
    }

    /// 把模型返回里的占位符换回原文;返回还原文本与丢失的占位符数
    static func restore(_ text: String, map: [String: String]) -> (String, lost: Int) {
        var out = text
        var lost = 0
        for (token, original) in map {
            if out.contains(token) {
                out = out.replacingOccurrences(of: token, with: original)
            } else {
                lost += 1
            }
        }
        return (out, lost)
    }

    // MARK: - 各类型扫描

    private static func scan(_ kind: Kind, in ns: NSString) -> [Hit] {
        switch kind {
        case .phone:
            return regexHits(#"(?<![0-9])1[3-9][0-9]{9}(?![0-9])"#, in: ns) { m in
                let s = ns.substring(with: m.range)
                return Hit(kind: .phone, range: m.range,
                           masked: String(s.prefix(3)) + "****" + String(s.suffix(4)))
            }
        case .idcard:
            return regexHits(#"(?<![0-9])[0-9]{17}[0-9Xx](?![0-9])"#, in: ns) { m in
                let s = ns.substring(with: m.range)
                guard validIDCard(s) else { return nil }
                return Hit(kind: .idcard, range: m.range,
                           masked: String(s.prefix(6)) + "********" + String(s.suffix(4)))
            }
        case .bankcard:
            return regexHits(#"(?<![0-9])[0-9]{13,19}(?![0-9])"#, in: ns) { m in
                let s = ns.substring(with: m.range)
                // 手机号是 11 位子集,已通过范围排除;Luhn 校验排除订单号等
                guard luhn(s) else { return nil }
                return Hit(kind: .bankcard, range: m.range,
                           masked: String(s.prefix(4)) + " **** **** " + String(s.suffix(4)))
            }
        case .email:
            return regexHits(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: ns) { m in
                let s = ns.substring(with: m.range)
                guard let at = s.firstIndex(of: "@") else { return nil }
                let masked = String(s.prefix(1)) + "***" + s[at...]
                return Hit(kind: .email, range: m.range, masked: String(masked))
            }
        case .apikey:
            let patterns = [
                #"sk-[A-Za-z0-9_-]{10,}"#,
                #"ghp_[A-Za-z0-9]{20,}"#,
                #"github_pat_[A-Za-z0-9_]{20,}"#,
                #"AKIA[0-9A-Z]{16}"#,
                #"xox[baprs]-[A-Za-z0-9-]{10,}"#,
                #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#,  // JWT
            ]
            return patterns.flatMap { p in
                regexHits(p, in: ns) { m in
                    let s = ns.substring(with: m.range)
                    let prefixLen = s.hasPrefix("sk-") ? 3 : 4
                    return Hit(kind: .apikey, range: m.range,
                               masked: String(s.prefix(prefixLen)) + "****" + String(s.suffix(4)))
                }
            }
        case .privatekey:
            return regexHits(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
                             in: ns) { m in
                Hit(kind: .privatekey, range: m.range,
                    masked: L10n.t("[已移除私钥]", "[private key removed]"))
            }
        case .internalip:
            return regexHits(
                #"\b(?:10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})\b"#,
                in: ns) { m in
                let s = ns.substring(with: m.range)
                let first = s.split(separator: ".").first ?? ""
                return Hit(kind: .internalip, range: m.range, masked: "\(first).***.***.***")
            }
        }
    }

    private static func regexHits(_ pattern: String, in ns: NSString,
                                  transform: (NSTextCheckingResult) -> Hit?) -> [Hit] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: ns as String,
                          range: NSRange(location: 0, length: ns.length))
            .compactMap(transform)
    }

    /// 身份证末位校验码
    static func validIDCard(_ s: String) -> Bool {
        let chars = Array(s.uppercased())
        guard chars.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let codes = Array("10X98765432")
        var sum = 0
        for i in 0..<17 {
            guard let d = chars[i].wholeNumberValue else { return false }
            sum += d * weights[i]
        }
        return codes[sum % 11] == chars[17]
    }

    /// Luhn 校验(银行卡)
    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count == s.count, digits.count >= 13 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            var v = d
            if i % 2 == 1 { v *= 2; if v > 9 { v -= 9 } }
            sum += v
        }
        return sum % 10 == 0
    }
}

/// ask 模式下用户的选择
enum SensitiveDecision {
    case masked        // 脱敏后发送(占位符,显示时还原)
    case sendAnyway    // 仍然发送原文
    case cancel
}

/// #16 发送前把关:本地 provider 直接放行;远端按 privacy.guardMode 处理。
enum SensitiveGuard {
    enum Check {
        /// 直接发送(可能附带占位符还原映射)
        case send(text: String, restore: ((String) -> String)?)
        /// 需要用户决定(ask 模式且命中敏感信息)
        case ask(hits: [SensitiveDetector.Hit], sendText: String, map: [String: String])
        /// 无敏感信息
        case clean
    }

    static func isLocal(_ provider: LLMProvider) -> Bool {
        let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
            || host.hasSuffix(".local") || host.hasPrefix("192.168.")
            || host.hasPrefix("10.") || host.hasPrefix("172.")
    }

    static func enabledKinds() -> Set<SensitiveDetector.Kind> {
        let types = ConfigStore.shared.config.privacy.types
        return Set(SensitiveDetector.Kind.allCases.filter { types.contains($0.rawValue) })
    }

    /// 检查待发文本;mode=off/本地 provider/无命中 → 直接发
    static func check(text: String, provider: LLMProvider) -> Check {
        let mode = ConfigStore.shared.config.privacy.guardMode
        guard mode != "off", !isLocal(provider) else { return .clean }
        let hits = SensitiveDetector.detect(text, types: enabledKinds())
        guard !hits.isEmpty else { return .clean }
        let (masked, map) = SensitiveDetector.placeholders(text, hits: hits)
        let restore: (String) -> String = { SensitiveDetector.restore($0, map: map).0 }
        switch mode {
        case "mask": return .send(text: masked, restore: restore)
        default:     return .ask(hits: hits, sendText: masked, map: map)
        }
    }

    /// 工具条「脱敏」动作:检测到敏感信息时作为上下文按钮出现,就地替换
    static func maskAction() -> BarAction? {
        BarAction(
            id: "builtin.mask", title: L10n.t("脱敏(打码敏感信息)", "Mask sensitive info"),
            symbol: "eye.slash", color: .systemOrange,
            isAvailable: { ctx in
                ctx.canReplace &&
                !SensitiveDetector.detect(ctx.text, types: enabledKinds()).isEmpty
            }) { ctx in
            let hits = SensitiveDetector.detect(ctx.text, types: enabledKinds())
            let masked = SensitiveDetector.mask(ctx.text, hits: hits)
            FloatingBarController.shared.hide()
            TextReplacer.replaceInline(masked)
        }
    }
}

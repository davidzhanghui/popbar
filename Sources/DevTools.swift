import Cocoa
import Foundation
import CryptoKit

/// #15 开发者文本工具箱:HTML/Unicode 转义、哈希、JWT 解码、JSON 处理。菜单动作。
enum DevTools {

    // MARK: - 转义

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// \u4f60\u597d → 你好(也处理 \xNN 与 &#NN;)
    static func unicodeUnescape(_ s: String) -> String {
        // \uXXXX 是十六进制 → &#xX; 实体;\xNN 同样
        var t = s.replacingOccurrences(
            of: "\\\\u([0-9A-Fa-f]{4})", with: "&#x$1;", options: .regularExpression)
        t = t.replacingOccurrences(
            of: "\\\\x([0-9A-Fa-f]{2})", with: "&#x$1;", options: .regularExpression)
        // &#NN; 用 NSMutableString 简单替换
        let ns = NSMutableString(string: t)
        let re = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);")
        let full = NSRange(location: 0, length: ns.length)
        for m in (re?.matches(in: ns as String, range: full) ?? []).reversed() {
            let g = ns.substring(with: m.range(at: 1))
            let code = g.hasPrefix("x") ? UInt32(g.dropFirst(), radix: 16) : UInt32(g)
            if let v = code, let sc = Unicode.Scalar(v) {
                ns.replaceCharacters(in: m.range, with: String(sc))
            }
        }
        return ns as String
    }

    static func unicodeEscape(_ s: String) -> String {
        s.unicodeScalars.map {
            $0.isASCII ? String($0) : String(format: "\\u%04X", $0.value)
        }.joined()
    }

    // MARK: - 哈希 / JWT

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JWT:解 header.payload,返回格式化的两段 JSON
    static func jwtDecode(_ s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        func b64url(_ x: String) -> Data? {
            var b = x.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            b += String(repeating: "=", count: (4 - b.count % 4) % 4)
            return Data(base64Encoded: b)
        }
        var out: [String] = []
        for (i, label) in [(0, "header"), (1, "payload")] {
            guard let d = b64url(parts[i]) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: d),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
               let str = String(data: pretty, encoding: .utf8) {
                out.append("// \(label)\n" + str)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n\n")
    }

    // MARK: - 工具条动作

    static func barAction() -> BarAction? {
        BarAction(id: "builtin.devtools", title: "Dev",
                  symbol: "terminal", color: .systemGreen,
                  menu: { c in
            ContextMenu.build([
                ContextMenu.Item(L10n.t("HTML 转义 → 替换", "HTML escape → Replace"), "chevron.left.forwardslash.chevron.right") {
                    TextReplacer.replaceInline(htmlEscape(c.text))
                },
                ContextMenu.Item(L10n.t("HTML 反转义 → 替换", "HTML unescape → Replace"), "chevron.left.forwardslash.chevron.right") {
                    TextReplacer.replaceInline(htmlUnescape(c.text))
                },
                ContextMenu.Item(L10n.t("Unicode 转义 → 替换", "Unicode escape → Replace"), "character.textbox") {
                    TextReplacer.replaceInline(unicodeEscape(c.text))
                },
                ContextMenu.Item(L10n.t("Unicode 反转义 → 替换", "Unicode unescape → Replace"), "character.textbox") {
                    TextReplacer.replaceInline(unicodeUnescape(c.text))
                },
                ContextMenu.Item(L10n.t("SHA256 → 复制", "SHA256 → Copy"), "number") {
                    PasteboardGuard.write(sha256(c.text))
                },
                ContextMenu.Item(L10n.t("MD5 → 复制", "MD5 → Copy"), "number") {
                    PasteboardGuard.write(md5(c.text))
                },
                ContextMenu.Item(L10n.t("JWT 解码", "Decode JWT"), "key") {
                    if let d = jwtDecode(c.text) {
                        OutputPanel.show(text: d, title: "JWT")
                    }
                },
                ContextMenu.Item(L10n.t("JSON 格式化 → 替换", "JSON pretty → Replace"), "curlybraces") {
                    if let s = ActionRegistry.jsonPretty(c.text) {
                        TextReplacer.replaceInline(s)
                    }
                },
                ContextMenu.Item(L10n.t("JSON 压缩 → 替换", "JSON minify → Replace"), "curlybraces") {
                    if let s = ActionRegistry.jsonMinified(c.text) {
                        TextReplacer.replaceInline(s)
                    }
                },
            ])
        }) { _ in }
    }
}

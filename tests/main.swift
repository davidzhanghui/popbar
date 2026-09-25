import Cocoa
import Foundation

/// PopBar 纯逻辑测试:swiftc 编译 Sources(除 main.swift)+ 本文件后运行。
/// 用法:tests/run.sh;退出码非 0 即失败。

var failures = 0
var checks = 0

func expect(_ cond: Bool, _ name: String) {
    checks += 1
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name)") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    checks += 1
    if a == b { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) — 期望 \(b),得到 \(a)") }
}

func section(_ s: String) { print("\n[\(s)]") }

// MARK: - ContextDetector

section("ContextDetector.url")
for s in ["https://github.com", "www.example.com", "example.com", "a.bc/c?x=1"] {
    expect(ContextDetector.isURLLike(s), "url: \(s)")
}
for s in ["hello world", "foo", "a.b", "say hello.com hi"] {
    expect(!ContextDetector.isURLLike(s), "not url: \(s)")
}

section("ContextDetector.email")
expect(ContextDetector.isEmail("a@b.co"), "email basic")
expect(!ContextDetector.isEmail("a@b"), "email missing tld")
expect(!ContextDetector.isEmail("a b@c.com"), "email with space")

section("ContextDetector.calc")
expectEqual(ContextDetector.evaluate("1+2*3"), "7", "calc 1+2*3")
expectEqual(ContextDetector.evaluate("(2+3)*4"), "20", "calc (2+3)*4")
expectEqual(ContextDetector.evaluate("10/4"), "2.5", "calc 10/4")
expectEqual(ContextDetector.evaluate("-3+5"), "2", "calc negative")
expectEqual(ContextDetector.evaluate("10%3+1"), "2", "calc mod")
expect(ContextDetector.evaluate("1/0") == nil, "calc div0 nil")
expect(ContextDetector.evaluate("123") == nil, "calc bare number nil")
expect(ContextDetector.evaluate("hello") == nil, "calc text nil")
expect(ContextDetector.evaluate("1+2abc") == nil, "calc trailing garbage nil")

section("ContextDetector.detect")
let kinds = ContextDetector.detect("https://a.com")
expect(kinds.contains(.url("https://a.com")), "detect url")

section("ContextDetector.timestamp")
expect(ContextDetector.asTimestamp("1727222400") != nil, "ts seconds")
expect(ContextDetector.asTimestamp("1727222400000") != nil, "ts millis")
expect(ContextDetector.asTimestamp("123") == nil, "ts short nil")
expect(ContextDetector.asTimestamp("9999999999") == nil, "ts out of range nil")

section("ContextDetector.json")
expect(ContextDetector.isJSON("{\"a\":1}"), "json object")
expect(ContextDetector.isJSON("[1,2]"), "json array")
expect(!ContextDetector.isJSON("{bad}"), "json bad nil")

section("ContextDetector.base64")
expect(ContextDetector.isBase64("aGVsbG8gd29ybGQ="), "base64 hello")
expect(!ContextDetector.isBase64("hi"), "base64 short nil")
expectEqual(ActionRegistry.base64Decode("aGVsbG8="), "hello", "b64 decode")

section("ContextDetector.urlEncoded")
expect(ContextDetector.isURLEncoded("hello%20world"), "urlenc")
expect(!ContextDetector.isURLEncoded("hello world"), "urlenc plain nil")

section("ContextDetector.color")
expect(ContextDetector.asColor("#FF6600") != nil, "hex6")
expect(ContextDetector.asColor("#F60") != nil, "hex3")
expect(ContextDetector.asColor("rgb(255, 102, 0)") != nil, "rgb")
expect(ContextDetector.asColor("hsl(24, 100%, 50%)") != nil, "hsl")
expect(ContextDetector.asColor("hello") == nil, "color text nil")
expectEqual(ActionRegistry.colorHex(ContextDetector.asColor("#FF6600")!), "#FF6600", "hex roundtrip")

section("ContextDetector.filePath")
expect(ContextDetector.asFilePath("/tmp") == "/tmp", "path /tmp")
expect(ContextDetector.asFilePath("/nonexistent/xyz") == nil, "path missing nil")
expect(ContextDetector.asFilePath("hello") == nil, "path text nil")

section("ContextDetector.money/unit")
let m = ContextDetector.asMoney("¥128")
expect(m?.0 == 128 && m?.1 == "CNY", "money yen")
expect(ContextDetector.asMoney("$20")?.1 == "USD", "money usd")
let u = ContextDetector.asUnit("80kg")
expect(u?.0 == 80 && u?.1 == "kg", "unit kg")
expect(ContextDetector.asUnit("5 miles")?.1 == "mile", "unit mile")
expect(ActionRegistry.convertUnit(1, "kg").contains("2.21"), "kg→lb")
expect(ActionRegistry.convertMoney(7.2, "USD").contains("CNY"), "usd→cny conv")

// MARK: - DevTools(#15)

section("DevTools")
expectEqual(DevTools.htmlEscape("<a>"), "&lt;a&gt;", "htmlEsc")
expectEqual(DevTools.htmlUnescape("&lt;a&gt;"), "<a>", "htmlUnesc")
expectEqual(DevTools.unicodeUnescape("\\u4F60\\u597D"), "你好", "uniUnesc")
expectEqual(DevTools.unicodeEscape("你"), "\\u4F60", "uniEsc")
expectEqual(DevTools.sha256("a").count, 64, "sha256 len")
expect(DevTools.jwtDecode("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.x")?
    .contains("HS256") == true, "jwt decode")

// MARK: - Config decode(向后兼容)

section("PopBarConfig decode")
let minimal = "{}".data(using: .utf8)!
let cfg = try! JSONDecoder().decode(PopBarConfig.self, from: minimal)
expectEqual(cfg.timeout, 30, "default timeout")
expectEqual(cfg.toolbar.maxVisible, 12, "default maxVisible")
expect(!cfg.extensions.isEmpty, "seeded extensions")
expect(cfg.appRules.contains { $0.bundleID == "com.1password.1password" },
       "seeded appRules")

let legacy = """
{"sourceLanguage":"auto","targetLanguage":"auto","timeout":15,
 "providers":[{"name":"A","baseURL":"https://x","model":"m","apiKey":"k","enabled":true}]}
""".data(using: .utf8)!
let legacyCfg = try! JSONDecoder().decode(PopBarConfig.self, from: legacy)
expectEqual(legacyCfg.timeout, 15, "legacy timeout")
expectEqual(legacyCfg.providers.count, 1, "legacy providers")
expect(!legacyCfg.providers[0].id.isEmpty, "provider id backfilled")
expect(legacyCfg.appRule(for: "com.1password.1password")?.mode == "disabled",
       "appRule lookup")

// MARK: - ActionRegistry(默认顺序与 0.1 版一致)

section("ActionRegistry")
let ctx = SourceContext(text: "hello", origin: .selection)
let resolved = ActionRegistry.resolve(for: ctx)
let ids = resolved.visible.map { $0.id }
expectEqual(Array(ids.prefix(5)),
            ["builtin.copy", "builtin.cut", "builtin.case", "builtin.google", "builtin.baidu"],
            "default order prefix")
expect(ids.contains("builtin.ai"), "ai action present")
expectEqual(ids.last, "builtin.devtools", "Dev 固定在工具条末位")
// 防回归:defaultOrder 里每个 id 都必须真的有对应动作(注册被误删时立刻失败)。
// 部分动作有条件出现(如脱敏要求文本含敏感信息),所以并上敏感文本的上下文。
let sensCtx = SourceContext(text: "联系我 13800138000", origin: .selection)
let allIds = Set(ActionRegistry.actions(for: ctx).map { $0.id })
    .union(ActionRegistry.actions(for: sensCtx).map { $0.id })
for id in BuiltinActions.defaultOrder {
    expect(allIds.contains(id), "defaultOrder 有对应动作: \(id)")
}
for id in ["builtin.devtools", "builtin.qrcode", "builtin.mask",
           "builtin.speak", "builtin.stats"] {
    expect(allIds.contains(id), "动作已注册: \(id)")
}
// url 上下文插在编辑组后
let ctxURL = SourceContext(text: "https://a.com", origin: .selection)
let r2 = ActionRegistry.resolve(for: ctxURL)
let ids2 = r2.visible.map { $0.id }
expectEqual(ids2.firstIndex(of: "ctx.openURL") ?? -1,
            (ids2.firstIndex(of: "builtin.case") ?? 0) + 1, "ctx after edit group")

// appRules custom 过滤
var cfgCustom = PopBarConfig()
cfgCustom.appRules = [AppRule(bundleID: "com.test.app", mode: "custom",
                              actions: ["builtin.copy"])]
let savedConfig = ConfigStore.shared.config
ConfigStore.shared.config = cfgCustom
var ctxApp = SourceContext(text: "hi", origin: .selection)
ctxApp.bundleID = "com.test.app"
let r3 = ActionRegistry.resolve(for: ctxApp)
expectEqual(r3.visible.count + r3.overflow.count, 1, "custom rule keeps one action")
ConfigStore.shared.config = savedConfig

// toolbar items 排序 + 隐藏进溢出
var cfgBar = PopBarConfig()
cfgBar.toolbar.items = [
    ToolbarItem(id: "builtin.copy", visible: true),
    ToolbarItem(id: "builtin.cut", visible: false),
]
ConfigStore.shared.config = cfgBar
let r4 = ActionRegistry.resolve(for: ctx)
expectEqual(r4.visible.first?.id, "builtin.copy", "toolbar order respected")
expect(r4.overflow.contains { $0.id == "builtin.cut" }, "hidden item in overflow")
expect(r4.overflow.contains { $0.id == "builtin.speak" }, "unlisted item in overflow")
ConfigStore.shared.config = savedConfig

// MARK: - SensitiveDetector

section("SensitiveDetector")
let kinds2 = Set(SensitiveDetector.Kind.allCases)
let hitsPhone = SensitiveDetector.detect("电话是13812345678,订单20200101", types: kinds2)
expectEqual(hitsPhone.count, 1, "phone detected once")
expectEqual(hitsPhone.first?.kind, .phone, "phone kind")
let hitsId = SensitiveDetector.detect("id 110101199003071234", types: kinds2)
expect(hitsId.isEmpty, "idcard bad checksum rejected")
let hitsIdOK = SensitiveDetector.detect("id 11010119900307731X", types: kinds2)
expectEqual(hitsIdOK.count, 1, "idcard valid checksum")
let hitsKey = SensitiveDetector.detect("key: sk-abc123def456ghi789", types: kinds2)
expectEqual(hitsKey.first?.kind, .apikey, "sk- key")
let hitsKeyShort = SensitiveDetector.detect("word sk-abc", types: kinds2)
expect(hitsKeyShort.isEmpty, "short sk- not key")
let hitsPk = SensitiveDetector.detect(
    "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----", types: kinds2)
expectEqual(hitsPk.first?.kind, .privatekey, "private key block")
let hitsIp = SensitiveDetector.detect("server 192.168.1.10 and 8.8.8.8", types: kinds2)
expectEqual(hitsIp.count, 1, "internal ip only")

let (maskedText, map) = SensitiveDetector.placeholders(
    "call 13812345678 ok", hits: SensitiveDetector.detect("call 13812345678 ok", types: kinds2))
expect(maskedText.contains("⟦PHONE_1⟧"), "placeholder inserted")
expect(!maskedText.contains("13812345678"), "original gone from masked")
let (restored, lost) = SensitiveDetector.restore("请打 ⟦PHONE_1⟧", map: map)
expectEqual(restored, "请打 13812345678", "placeholder restored")
expectEqual(lost, 0, "nothing lost")
expectEqual(SensitiveDetector.mask("call 13812345678", hits: SensitiveDetector.detect("call 13812345678", types: kinds2)),
            "call 138****5678", "inline mask")

expect(SensitiveGuard.isLocal(LLMProvider(name: "o", baseURL: "http://127.0.0.1:11434/v1",
                                        model: "m", apiKey: "k", enabled: true)),
       "local provider detected")
expect(!SensitiveGuard.isLocal(LLMProvider(name: "d", baseURL: "https://api.deepseek.com",
                                         model: "m", apiKey: "k", enabled: true)),
       "remote provider detected")

// MARK: - UsageStats(不落盘断言这里只做接口冒烟)

section("UsageStats")
expect(UsageStats.shared.topActions(for: "nobody", limit: 3).isEmpty, "empty top actions")

print("\n========== \(checks) 项检查,\(failures) 项失败 ==========")
exit(failures == 0 ? 0 : 1)

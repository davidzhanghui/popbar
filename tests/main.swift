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

section("Snap config decode")
let snapLegacy = """
{"hotkeys":{"showBar":"ctrl+opt+x"}}
""".data(using: .utf8)!
let snapCfg = try! JSONDecoder().decode(PopBarConfig.self, from: snapLegacy)
expectEqual(snapCfg.hotkeys.showBar, "ctrl+opt+x", "custom showBar preserved")
expectEqual(snapCfg.hotkeys.snap, "ctrl+opt+p", "snap hotkey default")
expectEqual(snapCfg.hotkeys.history, "opt+cmd+v", "history hotkey default")
expectEqual(snapCfg.snap, SnapConfig(), "snap config default")
expectEqual(snapCfg.snap.saveDir, "~/Desktop", "snap saveDir default")
let snapPartial = try! JSONDecoder().decode(PopBarConfig.self,
    from: "{\"snap\":{\"format\":\"jpg\"}}".data(using: .utf8)!)
expectEqual(snapPartial.snap.format, "jpg", "snap partial format")
expect(snapPartial.snap.showMagnifier, "snap partial keeps magnifier default")

section("Hotkey.parse snap")
let snapKey = Hotkey.parse("ctrl+opt+p")
expectEqual(snapKey?.key, 35, "ctrl+opt+p key code")
expect(snapKey?.flags == [.maskControl, .maskAlternate], "ctrl+opt+p flags")

section("SnapGeometry")
let sr = CGRect(x: 100, y: 100, width: 200, height: 100)
expect(SnapGeometry.hitHandle(CGPoint(x: 100, y: 200), rect: sr) == .topLeft, "hit topLeft")
expect(SnapGeometry.hitHandle(CGPoint(x: 300, y: 100), rect: sr) == .bottomRight, "hit bottomRight")
expect(SnapGeometry.hitHandle(CGPoint(x: 200, y: 200), rect: sr) == .top, "hit top")
expect(SnapGeometry.hitHandle(CGPoint(x: 200, y: 101), rect: sr) == .bottom, "hit bottom")
expect(SnapGeometry.hitHandle(CGPoint(x: 100, y: 150), rect: sr) == .left, "hit left")
expect(SnapGeometry.hitHandle(CGPoint(x: 300, y: 150), rect: sr) == .right, "hit right")
expect(SnapGeometry.hitHandle(CGPoint(x: 200, y: 150), rect: sr) == .inside, "hit inside")
expect(SnapGeometry.hitHandle(CGPoint(x: 50, y: 50), rect: sr) == nil, "hit outside")
let sb = CGRect(x: 0, y: 0, width: 1000, height: 800)
expectEqual(SnapGeometry.resize(sr, handle: .right, to: CGPoint(x: 400, y: 0), bounds: sb),
            CGRect(x: 100, y: 100, width: 300, height: 100), "resize right")
expectEqual(SnapGeometry.resize(sr, handle: .topLeft, to: CGPoint(x: 350, y: 50), bounds: sb),
            CGRect(x: 300, y: 50, width: 50, height: 50), "resize topLeft flips past bottomRight")
expectEqual(SnapGeometry.resize(sr, handle: .bottomRight, to: CGPoint(x: 2000, y: -50), bounds: sb),
            CGRect(x: 100, y: 0, width: 900, height: 200), "resize clamps to bounds")
expectEqual(SnapGeometry.move(sr, by: CGVector(dx: 10, dy: -20), bounds: sb),
            CGRect(x: 110, y: 80, width: 200, height: 100), "move")
expectEqual(SnapGeometry.move(sr, by: CGVector(dx: 5000, dy: -5000), bounds: sb),
            CGRect(x: 800, y: 0, width: 200, height: 100), "move clamps without shrinking")
expectEqual(SnapGeometry.rectFrom(CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 50), bounds: sb),
            CGRect(x: 100, y: 50, width: 200, height: 150), "rectFrom reversed")
expectEqual(SnapGeometry.rectFrom(CGPoint(x: 900, y: 700), CGPoint(x: 1500, y: 900), bounds: sb),
            CGRect(x: 900, y: 700, width: 100, height: 100), "rectFrom clamps")
expectEqual(SnapGeometry.pixelRect(CGRect(x: 10, y: 10, width: 20, height: 30), viewHeight: 100, scale: 2),
            CGRect(x: 20, y: 120, width: 40, height: 60), "pixelRect 2x y-flip")
let wins = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 500, height: 500)]
expectEqual(SnapGeometry.windowAt(CGPoint(x: 50, y: 50), windows: wins), wins[0], "windowAt front-most")
expectEqual(SnapGeometry.windowAt(CGPoint(x: 300, y: 300), windows: wins), wins[1], "windowAt behind")
expect(SnapGeometry.windowAt(CGPoint(x: 600, y: 600), windows: wins) == nil, "windowAt none")

section("SnapUndoStack")
var undoStack = SnapUndoStack<Int>()
expect(!undoStack.canUndo && !undoStack.canRedo, "empty stack")
undoStack.push(1); undoStack.push(2)
expectEqual(undoStack.items, [1, 2], "push")
undoStack.undo()
expectEqual(undoStack.items, [1], "undo")
expect(undoStack.canRedo, "canRedo after undo")
undoStack.redo()
expectEqual(undoStack.items, [1, 2], "redo")
undoStack.undo()
undoStack.push(3)
expectEqual(undoStack.items, [1, 3], "push after undo")
expect(!undoStack.canRedo, "push clears redo")
undoStack.undo(); undoStack.undo()
expect(!undoStack.canUndo, "canUndo false when empty")

section("SnapGeometry constrain/snap")
let o = CGPoint(x: 10, y: 10)
expectEqual(SnapGeometry.constrainSquare(from: o, to: CGPoint(x: 40, y: 20)), CGPoint(x: 40, y: 40), "square NE")
expectEqual(SnapGeometry.constrainSquare(from: o, to: CGPoint(x: -20, y: 15)), CGPoint(x: -20, y: 40), "square NW")
expectEqual(SnapGeometry.constrainSquare(from: o, to: CGPoint(x: 15, y: -30)), CGPoint(x: 50, y: -30), "square SE")
expectEqual(SnapGeometry.constrainSquare(from: o, to: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0), "square SW")
let sh = SnapGeometry.snapAngle(from: .zero, to: CGPoint(x: 10, y: 1))
expect(abs(sh.x - 10.05) < 0.01 && abs(sh.y) < 0.001, "snapAngle horizontal keeps length")
let sd = SnapGeometry.snapAngle(from: .zero, to: CGPoint(x: 10, y: 9))
expect(abs(sd.x - sd.y) < 0.001 && abs(hypot(sd.x, sd.y) - hypot(10, 9)) < 0.001, "snapAngle 45 degrees")

section("SnapOutput.compose")
func rgbaContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let whiteCtx = rgbaContext(200, 100)
whiteCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
whiteCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
let whiteImg = whiteCtx.makeImage()!
func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let c = rgbaContext(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    let o = (y * img.width + x) * 4
    return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
}
let plain = SnapOutput.compose(image: whiteImg, scale: 2, selection: CGRect(x: 10, y: 10, width: 50, height: 25), viewHeight: 50)
expectEqual(plain.width, 100, "crop width px")
expectEqual(plain.height, 50, "crop height px")
let red = SnapStyle(color: SnapStyle.color(hex: "#FF3B30")!, tier: 1)
let annotated = SnapOutput.compose(image: whiteImg, scale: 2, selection: CGRect(x: 10, y: 10, width: 50, height: 25),
                                   viewHeight: 50, annotations: [.rect(CGRect(x: 20, y: 20, width: 20, height: 10), red)])
expectEqual(annotated.width, 100, "annotated width px")
expectEqual(annotated.height, 50, "annotated height px")
let edge = pixel(annotated, 20, 20)
expect(edge.0 > 200 && edge.1 < 100, "rect edge is red")
let mid = pixel(annotated, 50, 25)
expect(mid.0 > 250 && mid.1 > 250 && mid.2 > 250, "center stays white")
expectEqual(SnapStyle.palette.count, 6, "six palette colors")
expectEqual(SnapStyle(color: SnapStyle.color(hex: "#34C759")!, tier: 0).hex, "#34C759", "style hex roundtrip")

section("SnapMosaic")
let mosaic = SnapMosaic.make(whiteImg, scale: 2)
expectEqual(mosaic?.width, 200, "mosaic width")
expectEqual(mosaic?.height, 100, "mosaic height")

section("SnapStitcher")
let stW = 40
func pageRowColor(_ r: Int) -> (UInt8, UInt8, UInt8) { (UInt8(r % 251), UInt8((r / 251) % 251), UInt8((r * 7) % 253)) }
/// 把 rows 里每个行号编码成一行纯色,拼成图
func stImage(_ rows: [Int]) -> CGImage {
    let ctx = rgbaContext(stW, rows.count)
    for (i, r) in rows.enumerated() {
        let c = pageRowColor(r)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: rows.count - 1 - i, width: stW, height: 1))
    }
    return ctx.makeImage()!
}
func stRows(_ img: CGImage) -> [Int] {
    let ctx = rgbaContext(img.width, img.height)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let lookup = Dictionary(uniqueKeysWithValues: (0..<20000).map { r -> ([UInt8], Int) in
        let c = pageRowColor(r); return ([c.0, c.1, c.2], r) })
    return (0..<img.height).map { y in lookup[[p[y * img.width * 4], p[y * img.width * 4 + 1], p[y * img.width * 4 + 2]]] ?? -1 }
}
/// 页面第 offset 起 h 行,头部 header 行与尾部 footer 行为固定内容(行号 5000+)
func stFrame(_ offset: Int, h: Int, header: Int = 0, footer: Int = 0) -> CGImage {
    var rows: [Int] = (0..<header).map { 5000 + $0 }
    rows += (0..<(h - header - footer)).map { offset + $0 }
    rows += (0..<footer).map { 6000 + $0 }
    return stImage(rows)
}

var st1 = SnapStitcher(first: stFrame(0, h: 200))!
expectEqual(st1.add(stFrame(50, h: 200)), .appended(50), "stitch 50")
expectEqual(st1.add(stFrame(130, h: 200)), .appended(80), "stitch 80")
expectEqual(st1.add(stFrame(130, h: 200)), .unchanged, "stitch unchanged")
expectEqual(st1.add(stFrame(260, h: 200)), .appended(130), "stitch 130")
let st1Img = st1.finalImage()!
expectEqual(st1Img.height, 460, "stitch height")
expectEqual(stRows(st1Img), Array(0..<460), "stitch rows contiguous")

var st2 = SnapStitcher(first: stFrame(0, h: 200, header: 20, footer: 15))!
for o in [40, 100, 180] { _ = st2.add(stFrame(o, h: 200, header: 20, footer: 15)) }
expectEqual(stRows(st2.finalImage()!),
            (0..<20).map { 5000 + $0 } + Array(0..<345) + (0..<15).map { 6000 + $0 }, "header/footer stitched once")

var st3 = SnapStitcher(first: stFrame(0, h: 200))!
expectEqual(st3.add(stFrame(190, h: 200)), .tooFast, "jump too large")
expectEqual(st3.finalImage()!.height, 200, "too fast leaves result")

var st4 = SnapStitcher(first: stFrame(0, h: 200))!
expectEqual(st4.add(stFrame(100, h: 200)), .appended(100), "stitch before upward")
expectEqual(st4.add(stFrame(40, h: 200)), .upward, "upward detected")

let blankCtx = rgbaContext(stW, 200)
blankCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
blankCtx.fill(CGRect(x: 0, y: 0, width: stW, height: 200))
var st5 = SnapStitcher(first: blankCtx.makeImage()!)!
let blankResult = st5.add(blankCtx.makeImage()!)
expect(blankResult == .unchanged || blankResult == .ambiguous, "blank frames not appended")

var st6 = SnapStitcher(first: stFrame(0, h: 200), maxHeight: 300)!
var limitHit = false
for o in [80, 160] { if st6.add(stFrame(o, h: 200)) == .limitReached { limitHit = true } }
expect(limitHit, "limit reached")
expectEqual(st6.finalImage()!.height, 300, "limited height")

section("SnapHistory.toDelete")
let histNames = (0..<25).map { String(format: "20260101-1200%02d-000@2x.png", $0) }
expectEqual(SnapHistory.toDelete(histNames, limit: 20), Array(histNames.prefix(5).reversed()), "oldest five deleted")
expectEqual(SnapHistory.toDelete(histNames, limit: 0).count, 24, "limit clamps to 1")
expectEqual(SnapHistory.toDelete(histNames, limit: 500).count, 0, "limit clamps to 200")

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

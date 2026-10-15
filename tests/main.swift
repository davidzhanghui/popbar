import Cocoa
import Foundation
@preconcurrency import AVFoundation

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

section("Hotkey.parse record")
let recKey = Hotkey.parse("ctrl+opt+r")
expectEqual(recKey?.key, 15, "ctrl+opt+r key code")
expect(recKey?.flags == [.maskControl, .maskAlternate], "ctrl+opt+r flags")
let pauseKey = Hotkey.parse("ctrl+opt+shift+r")
expectEqual(pauseKey?.key, 15, "ctrl+opt+shift+r key code")
expect(pauseKey?.flags == [.maskControl, .maskAlternate, .maskShift], "ctrl+opt+shift+r flags")

section("RecordConfig decode")
let recCfg = try! JSONDecoder().decode(PopBarConfig.self, from: "{}".data(using: .utf8)!)
expectEqual(recCfg.hotkeys.record, "ctrl+opt+r", "record hotkey default")
expectEqual(recCfg.hotkeys.recordPause, "ctrl+opt+shift+r", "recordPause hotkey default")
expectEqual(recCfg.snap.record, RecordConfig(), "record config default")
expectEqual(recCfg.snap.record.fps, 30, "default fps 30")
expectEqual(recCfg.snap.record.scale, 2, "default scale 2")
expectEqual(recCfg.snap.record.codec, "h264", "default codec h264")
expectEqual(recCfg.snap.record.container, "mov", "default container mov")
expect(recCfg.snap.record.showsCursor && recCfg.snap.record.systemAudio, "cursor+audio on by default")
expect(!recCfg.snap.record.microphone, "microphone off by default")
expectEqual(recCfg.snap.record.gif.width, 800, "gif default width")
let recFull = try! JSONDecoder().decode(RecordConfig.self, from: """
{"fps":60,"scale":1,"codec":"hevc","container":"mp4","showsCursor":false,
 "systemAudio":false,"microphone":true,"microphoneDevice":"mic-1","maxDuration":30,
 "gif":{"fps":15,"width":480,"copyToClipboard":false}}
""".data(using: .utf8)!)
expectEqual(recFull.fps, 60, "fps 60 kept")
expectEqual(recFull.scale, 1, "scale 1 kept")
expectEqual(recFull.codec, "hevc", "codec hevc kept")
expectEqual(recFull.container, "mp4", "container mp4 kept")
expect(!recFull.showsCursor && !recFull.systemAudio, "flags off kept")
expect(recFull.microphone && recFull.microphoneDevice == "mic-1", "microphone kept")
expectEqual(recFull.maxDuration, 30, "maxDuration kept")
expectEqual(recFull.gif.fps, 15, "gif fps kept")
expect(!recFull.gif.copyToClipboard, "gif clipboard flag kept")
let recBad = try! JSONDecoder().decode(RecordConfig.self, from: """
{"fps":1000,"scale":9,"codec":"vp9","container":"mkv","maxDuration":-5}
""".data(using: .utf8)!)
expectEqual(recBad.fps, 60, "fps clamped to 60")
expectEqual(recBad.scale, 2, "unknown scale falls back to 2")
expectEqual(recBad.codec, "h264", "unknown codec falls back to h264")
expectEqual(recBad.container, "mov", "unknown container falls back to mov")
expectEqual(recBad.maxDuration, 0, "negative maxDuration clamped to 0")

section("SpeakConfig decode")
let spkCfg = try! JSONDecoder().decode(PopBarConfig.self, from: "{}".data(using: .utf8)!)
expectEqual(spkCfg.speak, SpeakConfig(), "speak config default")
expect(spkCfg.speak.voice.isEmpty && spkCfg.speak.rate == 1.0, "voice auto + rate 1.0")
let spkFull = try! JSONDecoder().decode(SpeakConfig.self, from:
    #"{"voice":"com.apple.voice.enhanced.zh-CN.Tingting","rate":1.5}"#.data(using: .utf8)!)
expectEqual(spkFull.voice, "com.apple.voice.enhanced.zh-CN.Tingting", "voice identifier kept")
expectEqual(spkFull.rate, 1.5, "rate kept")
let spkBad = try! JSONDecoder().decode(SpeakConfig.self, from:
    #"{"voice":"gone","rate":9}"#.data(using: .utf8)!)
expectEqual(spkBad.rate, 2.0, "rate clamped to 2.0")
let spkLow = try! JSONDecoder().decode(SpeakConfig.self, from:
    #"{"rate":0.1}"#.data(using: .utf8)!)
expectEqual(spkLow.rate, 0.4, "rate clamped to 0.4")

// MARK: - 录屏(纯逻辑)

section("RecordUtil.evenPixel")
expectEqual(RecordUtil.evenPixel(100.6), 100, "even: 100.6 → 100")
expectEqual(RecordUtil.evenPixel(101), 100, "even: 101 → 100 向下对齐")
expectEqual(RecordUtil.evenPixel(1), 2, "even: 最小 2")
expectEqual(RecordUtil.evenPixel(0), 2, "even: 0 → 2")
expectEqual(RecordUtil.evenPixel(640 * 2), 1280, "even: retina 640pt")

section("RecordUtil.sourceRect")
let sFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
expectEqual(RecordUtil.sourceRect(global: CGRect(x: 100, y: 200, width: 300, height: 150), screenFrame: sFrame),
            CGRect(x: 100, y: 730, width: 300, height: 150), "sourceRect y 翻转")
let sFrame2 = CGRect(x: -800, y: 60, width: 800, height: 600)
expectEqual(RecordUtil.sourceRect(global: CGRect(x: -700, y: 100, width: 200, height: 100), screenFrame: sFrame2),
            CGRect(x: 100, y: 460, width: 200, height: 100), "sourceRect 副屏偏移")

section("RecordUtil.durationText")
expectEqual(RecordUtil.durationText(0), "00:00", "duration 0")
expectEqual(RecordUtil.durationText(9.4), "00:09", "duration 9.4")
expectEqual(RecordUtil.durationText(65), "01:05", "duration 65")
expectEqual(RecordUtil.durationText(3661), "1:01:01", "duration 1h1m1s")
expectEqual(RecordUtil.durationText(-5), "00:00", "duration 负数")

section("RecordUtil.fileName")
let stem = RecordUtil.fileStem(Date(timeIntervalSince1970: 1_726_000_000))
expect(stem.hasPrefix("PopBar-Rec-"), "stem 前缀")
expectEqual(stem.count, "PopBar-Rec-".count + 15, "stem 长度 yyyyMMdd-HHmmss")
let recDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("popbar-rec-test-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
let u1st = RecordUtil.uniqueURL(in: recDir, stem: "PopBar-Rec-20261012-120000", ext: "mov")
expectEqual(u1st.lastPathComponent, "PopBar-Rec-20261012-120000.mov", "首个文件名无后缀")
FileManager.default.createFile(atPath: u1st.path, contents: Data())
let u2nd = RecordUtil.uniqueURL(in: recDir, stem: "PopBar-Rec-20261012-120000", ext: "mov")
expectEqual(u2nd.lastPathComponent, "PopBar-Rec-20261012-120000-2.mov", "同名追加 -2")
FileManager.default.createFile(atPath: u2nd.path, contents: Data())
let u3rd = RecordUtil.uniqueURL(in: recDir, stem: "PopBar-Rec-20261012-120000", ext: "mov")
expectEqual(u3rd.lastPathComponent, "PopBar-Rec-20261012-120000-3.mov", "同名追加 -3")
try? FileManager.default.removeItem(at: recDir)

section("RecordUtil.byteText")
expectEqual(RecordUtil.byteText(512), "512 B", "bytes")
expectEqual(RecordUtil.byteText(2048), "2 KB", "KB")
expectEqual(RecordUtil.byteText(12_000_000), "11.4 MB", "MB")
expectEqual(RecordUtil.byteText(3_000_000_000), "2.79 GB", "GB")
expectEqual(RecordUtil.gifBytes(frames: 100, width: 800, height: 450), 10_800_000, "gif 预估")

section("RecordRectMemory")
let rmRect = CGRect(x: -300, y: 40, width: 640, height: 480)
expectEqual(RecordRectMemory.decode(RecordRectMemory.encode(rmRect)), rmRect, "rect 编解码往返")
expect(RecordRectMemory.decode("1,2,1,1") == nil, "过小的 rect 丢弃")
expect(RecordRectMemory.decode("a,b,c,d") == nil, "非数字丢弃")

section("RecordGIF.plan")
let p1 = RecordGIF.plan(duration: 10, size: CGSize(width: 1920, height: 1080), fps: 10, width: 800)
expectEqual(p1.frames, 100, "plan 帧数")
expectEqual(Int(p1.size.width), 800, "plan 宽度")
expectEqual(Int(p1.size.height), 450, "plan 等比高度")
let p2 = RecordGIF.plan(duration: 3, size: CGSize(width: 640, height: 480), fps: 10, width: 0)
expectEqual(p2.frames, 30, "plan 原始宽度帧数")
expectEqual(Int(p2.size.width), 640, "plan 原始宽度")
let p3 = RecordGIF.plan(duration: 0.2, size: CGSize(width: 1920, height: 1080), fps: 5, width: 480)
expectEqual(p3.frames, 1, "plan 极短至少 1 帧")

section("RecordGIF.clampRange")
let cr1 = RecordGIF.clampRange(span: 9.93, start: 0, end: nil)
expect(cr1.1 <= 9.93, "end 缺省钳到视频轨时长")
let cr2 = RecordGIF.clampRange(span: 9.93, start: 0, end: 11.4)
expect(cr2.1 <= 9.93, "end 超出视频轨时长被钳位")
let cr3 = RecordGIF.clampRange(span: 9.93, start: 12, end: nil)
expect(cr3.0 < cr3.1, "start 超界仍保留最小区间")
let cr4 = RecordGIF.clampRange(span: 10, start: 2, end: 5)
expect(cr4.0 == 2 && cr4.1 == 5, "正常区间原样返回")

// MARK: - 录屏 v2 纯逻辑

section("RecordUtil.estimatedBytesPerSecond")
// 1080p30 H.264 大约每分钟几十 MB 的量级,用于给用户一个体积概念
let eps = RecordUtil.estimatedBytesPerSecond(width: 1920, height: 1080, fps: 30, codec: "h264")
expect(eps > 300_000 && eps < 900_000, "1080p30 h264 码率落在合理区间(\(Int(eps)) B/s)")
expect(RecordUtil.estimatedBytesPerSecond(width: 1920, height: 1080, fps: 30, codec: "hevc") < eps,
       "HEVC 估计比 H.264 小")
expect(RecordUtil.estimatedBytesPerSecond(width: 0, height: 0, fps: 0, codec: "h264") == 0,
       "零尺寸不产生负数")
expect(RecordUtil.estimatedBytesPerSecond(width: 100, height: 100, fps: 60, codec: "h264")
       > RecordUtil.estimatedBytesPerSecond(width: 100, height: 100, fps: 30, codec: "h264"),
       "60fps 估计更大")

section("RecordExportUtil.targetSize")
let ts1 = RecordExportUtil.targetSize(source: CGSize(width: 320, height: 180), width: 160)
expect(ts1 == CGSize(width: 160, height: 90), "等比缩放到目标宽度")
let ts2 = RecordExportUtil.targetSize(source: CGSize(width: 320, height: 180), width: 0)
expect(ts2 == CGSize(width: 320, height: 180), "0 = 原始尺寸")
let ts3 = RecordExportUtil.targetSize(source: CGSize(width: 320, height: 180), width: 9999)
expect(ts3 == CGSize(width: 320, height: 180), "不放大")
let ts4 = RecordExportUtil.targetSize(source: CGSize(width: 300, height: 200), width: 101)
expect(Int(ts4.width) % 2 == 0 && Int(ts4.height) % 2 == 0, "宽高都对到偶数")
let ts5 = RecordExportUtil.targetSize(source: CGSize(width: 1, height: 1), width: 0)
expect(ts5.width >= 2 && ts5.height >= 2, "极小尺寸也有下限")

section("RecordExportUtil.clampRange")
let ec1 = RecordExportUtil.clampRange(span: 10, start: 2, end: 5)
expect(ec1.0 == 2 && ec1.1 == 5, "正常区间原样")
let ec2 = RecordExportUtil.clampRange(span: 10, start: 0, end: 99)
expect(ec2.1 == 10, "end 超界钳到时长")
let ec3 = RecordExportUtil.clampRange(span: 10, start: 20, end: nil)
expect(ec3.0 < ec3.1, "start 超界仍保留最小区间")
let ec4 = RecordExportUtil.clampRange(span: 10, start: 8, end: 3)
expect(ec4.1 > ec4.0, "end 早于 start 时钳成最小区间")

section("RecordExportUtil.presetName")
expectEqual(RecordExportUtil.presetName(quality: "high", width: 1920),
            AVAssetExportPresetHighestQuality, "高质量档")
expectEqual(RecordExportUtil.presetName(quality: "low", width: 1920),
            AVAssetExportPreset1280x720, "低质量档用 720p 预设")
expectEqual(RecordExportUtil.presetName(quality: "medium", width: 854),
            AVAssetExportPreset1280x720, "小尺寸的中档不必上 1080p")

section("RecordExportUtil.rgb")
let rgb1 = RecordExportUtil.rgb("#FF3B30")
expect(rgb1 != nil && abs(rgb1!.0 - 1) < 0.001 && rgb1!.1 < 0.3, "#RRGGBB 解析")
expect(RecordExportUtil.rgb("0A84FF") != nil, "不带 # 也能解析")
expect(RecordExportUtil.rgb("#f00") != nil, "三位简写展开")
expect(RecordExportUtil.rgb("nope") == nil, "非法输入返回 nil")

section("RecordExportUtil 坐标约定")
let render = CGSize(width: 160, height: 90)
// CA 动画层用左下原点:归一化 y=0.25(靠上)应换算成较大的 CA y
let lp = RecordExportUtil.layerPoint(x: 0.25, y: 0.25, renderSize: render)
expect(abs(lp.x - 40) < 0.01 && abs(lp.y - 67.5) < 0.01, "CA 位置 y 轴翻转")
// layerInstruction 的 transform 用左上原点:不做翻转
let rr = RecordExportUtil.renderRect(x: 0.7, y: 0.7, w: 0.25, h: 0.25, renderSize: render)
expect(abs(rr.minX - 112) < 0.01 && abs(rr.minY - 63) < 0.01, "层指令矩形不翻转")
let lr = RecordExportUtil.layerRect(x: 0.7, y: 0.7, w: 0.25, h: 0.25, renderSize: render)
expect(abs(lr.minX - 112) < 0.01 && abs(lr.minY - 4.5) < 0.01, "CA 矩形翻转")

section("RecordExportUtil.watermarkFrame")
let wf = RecordExportUtil.watermarkFrame(size: CGSize(width: 16, height: 16), renderSize: render,
                                         position: "topLeft", margin: 0.025)
expect(wf.minX >= 0 && wf.minY >= 0 && wf.maxY <= render.height, "水印留在画面内")
let wf2 = RecordExportUtil.watermarkFrame(size: CGSize(width: 16, height: 16), renderSize: render,
                                          position: "bottomRight", margin: 0.025)
expect(wf2.minX > wf.minX && wf2.minY < wf.minY, "右下角与左上角位置相反")

section("RecordExportUtil.volumePlan")
expectEqual(RecordExportUtil.volumePlan(trackCount: 0, micEnabled: false, system: 1, mic: 1), [], "没有音轨")
expectEqual(RecordExportUtil.volumePlan(trackCount: 1, micEnabled: false, system: 0.5, mic: 2), [0.5],
            "只有系统声音")
expectEqual(RecordExportUtil.volumePlan(trackCount: 1, micEnabled: true, system: 0.5, mic: 2), [0.5],
            "开了麦克风但只有一轨:取较小值")
expectEqual(RecordExportUtil.volumePlan(trackCount: 2, micEnabled: true, system: 0.4, mic: 1.5), [0.4, 1.5],
            "两轨:最后一轨是麦克风")
expectEqual(RecordExportUtil.volumePlan(trackCount: 2, micEnabled: false, system: 0.4, mic: 1.5), [0.4, 0.4],
            "没开麦克风时两轨同音量")

section("RecordExportUtil.placeTransform")
let pt = RecordExportUtil.placeTransform(naturalSize: CGSize(width: 320, height: 180),
                                         preferred: .identity, renderSize: CGSize(width: 160, height: 90))
expectEqual(pt, CGAffineTransform(scaleX: 0.5, y: 0.5), "等比缩小居中")
let ptFit = RecordExportUtil.placeTransform(naturalSize: CGSize(width: 160, height: 120),
                                            preferred: .identity, renderSize: CGSize(width: 40, height: 22.5))
let mapped = CGRect(origin: .zero, size: CGSize(width: 160, height: 120)).applying(ptFit)
expect(mapped.width <= 40.01 && mapped.height <= 22.51, "按短边缩放进目标矩形")
expect(abs(mapped.midX - 20) < 0.5, "水平居中")

section("RecordCameraLayout")
let cam = RecordCameraLayout.panelSize(width: 160, aspect: 4.0 / 3.0)
expect(abs(cam.height - 120) < 0.6, "4:3 摄像头 160 宽 → 120 高")
let cam16 = RecordCameraLayout.panelSize(width: 160, aspect: 16.0 / 9.0)
expect(abs(cam16.height - 90) < 0.6, "16:9 摄像头 160 宽 → 90 高")
expect(RecordCameraLayout.panelSize(width: 0, aspect: 0).width >= 64, "宽度有下限")
let ov = RecordCameraLayout.overlay(panelSize: CGSize(width: 32, height: 24),
                                    area: CGSize(width: 320, height: 180), position: "bottomRight")
expect(abs(ov.x - (1 - 0.02 - 0.1)) < 0.001 && abs(ov.y - (1 - 0.02 - 24.0 / 180)) < 0.001,
       "右下角归一化位置")
let ovTL = RecordCameraLayout.overlay(panelSize: CGSize(width: 32, height: 24),
                                      area: CGSize(width: 320, height: 180), position: "topLeft")
expect(abs(ovTL.x - 0.02) < 0.001 && abs(ovTL.y - 0.02) < 0.001, "左上角归一化位置")
let area = CGRect(x: 100, y: 200, width: 320, height: 180)
let cocoa = RecordCameraLayout.cocoaFrame(area: area, overlay: ov)
// 归一化 y 是左上原点,Cocoa 是左下原点:右下角的面板应该贴在 area 的右下,
// 与两条边各留 2% 边距
expect(abs((area.maxX - cocoa.maxX) - 0.02 * area.width) < 0.5, "右侧留给 2% 边距")
expect(abs(cocoa.minY - (area.minY + 0.02 * area.height)) < 0.5, "底部留给 2% 边距")
let cocoaTL = RecordCameraLayout.cocoaFrame(area: area, overlay: ovTL)
expect(abs(cocoaTL.minX - (area.minX + 0.02 * area.width)) < 0.5
       && abs(cocoaTL.maxY - (area.maxY - 0.02 * area.height)) < 0.5, "左上角面板贴住录制区的左上")

section("ClickRecorder.normalize")
let clickArea = CGRect(x: 100, y: 100, width: 200, height: 100)
let n1 = ClickRecorder.normalize(CGPoint(x: 200, y: 150), in: clickArea)
expect(n1 != nil && abs(n1!.0 - 0.5) < 0.001 && abs(n1!.1 - 0.5) < 0.001, "中心点 → (0.5,0.5)")
// Cocoa 左下原点 → 归一化左上原点:区域的「视觉左上角」(Cocoa maxY)应为 y=0,
// 「视觉左下角」(Cocoa minY)应为 y=1
let nTop = ClickRecorder.normalize(CGPoint(x: 100, y: 200), in: clickArea)
expect(nTop != nil && abs(nTop!.0) < 0.001 && abs(nTop!.1) < 0.001, "视觉左上角 → y=0")
let nBottom = ClickRecorder.normalize(CGPoint(x: 100, y: 100), in: clickArea)
expect(nBottom != nil && abs(nBottom!.1 - 1) < 0.001, "视觉左下角 → y=1")
expect(ClickRecorder.normalize(CGPoint(x: 100, y: 200.5), in: clickArea) == nil, "区域上方返回 nil")
expect(ClickRecorder.normalize(CGPoint(x: 50, y: 150), in: clickArea) == nil, "区域外返回 nil")
expect(ClickRecorder.normalize(CGPoint(x: 200, y: 150), in: .zero) == nil, "零尺寸区域返回 nil")

section("RecordDataStore.stableKey")
let k1 = RecordDataStore.stableKey("/Users/x/Movies/a.mov")
let k2 = RecordDataStore.stableKey("/Users/x/Movies/a.mov")
let k3 = RecordDataStore.stableKey("/Users/x/Movies/b.mov")
expectEqual(k1, k2, "同一路径稳定同 key")
expect(k1 != k3, "不同路径不同 key")
expectEqual(RecordDataStore.stableKey(""), "cbf29ce484222325", "空串 = FNV 偏移基数")

section("SnapGeometry.matchesWindow")
let win = CGRect(x: 10, y: 20, width: 300, height: 200)
expect(SnapGeometry.matchesWindow(win, window: win), "完全一致")
expect(SnapGeometry.matchesWindow(win.insetBy(dx: 1, dy: 1), window: win), "1pt 误差内算吸附")
expect(!SnapGeometry.matchesWindow(win.insetBy(dx: 10, dy: 0), window: win), "差太多不算")
let wins2 = [win, CGRect(x: 0, y: 0, width: 600, height: 400)]
expectEqual(SnapGeometry.windowIndex(at: CGPoint(x: 50, y: 50), in: wins2), 0, "命中前窗下标")
expectEqual(SnapGeometry.windowIndex(at: CGPoint(x: 500, y: 300), in: wins2), 1, "命中后窗下标")
expect(SnapGeometry.windowIndex(at: CGPoint(x: 9999, y: 9999), in: wins2) == nil, "未命中返回 nil")

section("RecordConfig v2 默认值与钳位")
let recV2 = RecordConfig()
expectEqual(recV2.countdown, 3, "默认倒计时 3 秒")
expect(recV2.windowFollow, "默认跟随窗口")
expect(!recV2.copyToClipboard, "默认不复制到剪贴板")
expect(recV2.click.enabled, "默认开启点击记录")
expect(!recV2.camera.enabled, "默认关摄像头")
expect(!recV2.watermark.enabled, "默认关水印")
expectEqual(recV2.export.container, "mp4", "导出默认 MP4")
let badCountdown = try! JSONDecoder().decode(RecordConfig.self, from: #"{"countdown":7}"#.data(using: .utf8)!)
expectEqual(badCountdown.countdown, 3, "非法倒计时回落默认")
let okCountdown = try! JSONDecoder().decode(RecordConfig.self, from: #"{"countdown":10}"#.data(using: .utf8)!)
expectEqual(okCountdown.countdown, 10, "合法倒计时保留")
let vol = try! JSONDecoder().decode(RecordConfig.self,
                                    from: #"{"export":{"systemVolume":9,"micVolume":-3}}"#.data(using: .utf8)!)
expectEqual(vol.export.systemVolume, 2, "音量上限 2")
expectEqual(vol.export.micVolume, 0, "音量下限 0")
let camBad = try! JSONDecoder().decode(RecordConfig.self,
                                       from: #"{"camera":{"position":"middle","size":9999}}"#.data(using: .utf8)!)
expectEqual(camBad.camera.position, "bottomRight", "非法摄像头位置回落默认")
expectEqual(camBad.camera.size, 480, "摄像头尺寸上限")
let clickBad = try! JSONDecoder().decode(RecordConfig.self,
                                         from: #"{"click":{"radius":9999,"duration":0.01}}"#.data(using: .utf8)!)
expectEqual(clickBad.click.radius, 200, "涟漪半径上限")
expectEqual(clickBad.click.duration, 0.15, "涟漪时长下限")
let hkV2 = HotkeysConfig()
expectEqual(hkV2.recordMarker, "ctrl+opt+shift+m", "默认标记快捷键")

section("RecordSidecar 编解码")
var sc = RecordSidecar()
sc.videoPath = "/tmp/a.mov"
sc.duration = 3.5
sc.micEnabled = true
sc.clicks = [ClickMark(t: 1.0, x: 0.5, y: 0.25, button: 0)]
sc.markers = [RecordMarker(t: 2.0)]
sc.camera = CameraSidecar(file: "camera.mov", x: 0.7, y: 0.7, width: 0.25, height: 0.25, mirror: true)
sc.areaRect = [0, 0, 100, 100]
let scData = try! JSONEncoder().encode(sc)
let sc2 = try! JSONDecoder().decode(RecordSidecar.self, from: scData)
expectEqual(sc2, sc, "sidecar 往返一致")
expect(sc2.area == CGRect(x: 0, y: 0, width: 100, height: 100), "areaRect 还原成 CGRect")
var scBad = RecordSidecar()
scBad.areaRect = [1, 2, 3]
expect(scBad.area == nil, "残缺 areaRect 返回 nil")

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

// MARK: - ClipboardHistory(纯逻辑;不碰 NSPasteboard)

section("ClipboardHistory")
func mkItem(_ payload: ClipboardHistory.Payload,
            pinned: Bool = false) -> ClipboardHistory.Item {
    ClipboardHistory.Item(id: UUID(), payload: payload, time: Date(),
                          pinned: pinned, thumbnail: nil)
}

// pick:类型优先级与跳过规则
expectEqual(ClipboardHistory.pick(types: ["public.utf8-plain-text"], images: true, files: true),
            .kind(.text), "pick text")
expectEqual(ClipboardHistory.pick(types: ["public.file-url", "public.utf8-plain-text"],
                                  images: true, files: true),
            .kind(.files), "pick files over text")
expectEqual(ClipboardHistory.pick(types: ["public.file-url", "public.utf8-plain-text"],
                                  images: true, files: false),
            .skip, "files disabled → skip")
expectEqual(ClipboardHistory.pick(types: ["public.tiff", "public.utf8-plain-text"],
                                  images: true, files: true),
            .kind(.image), "pick image over text")
expectEqual(ClipboardHistory.pick(types: ["public.tiff", "public.utf8-plain-text"],
                                  images: false, files: true),
            .skip, "images disabled → skip")
expectEqual(ClipboardHistory.pick(types: ["com.apple.is-remote-clipboard", "public.utf8-plain-text"],
                                  images: true, files: true),
            .skip, "remote clipboard → skip")
expectEqual(ClipboardHistory.pick(types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"],
                                  images: true, files: true),
            .skip, "concealed → skip")
expectEqual(ClipboardHistory.pick(types: ["com.foo.private"], images: true, files: true),
            .none, "unknown → none")

// evict:条数硬上限 + 置顶豁免 + 图片容量预算
let eleven = (0..<11).map { mkItem(.text("t\($0)")) }
let ev = ClipboardHistory.evict(eleven, limit: 10, imageBudgetBytes: 1 << 30)
expectEqual(ev.count, 10, "evict 11→10")
if case .text(let s) = ev.last?.payload {
    expectEqual(s, "t9", "oldest evicted")
} else { expect(false, "oldest evicted") }
let mixed = (0..<3).map { mkItem(.text("p\($0)"), pinned: true) }
    + (0..<8).map { mkItem(.text("n\($0)")) }
let ev2 = ClipboardHistory.evict(mixed, limit: 10, imageBudgetBytes: 1 << 30)
expectEqual(ev2.count, 10, "pinned+normal → 10")
expectEqual(ev2.filter { $0.pinned }.count, 3, "all pinned kept")
func imgItem(_ bytes: Int, pinned: Bool = false) -> ClipboardHistory.Item {
    mkItem(.image(.data(Data()), pixelSize: CGSize(width: 10, height: 10),
                  byteCount: bytes, hash: "\(bytes)"), pinned: pinned)
}
let imgs = [imgItem(30), imgItem(30), imgItem(30)]
let ev3 = ClipboardHistory.evict(imgs, limit: 10, imageBudgetBytes: 70)
expectEqual(ev3.count, 2, "image budget evicts oldest")
let ev4 = ClipboardHistory.evict([imgItem(100, pinned: true)], limit: 10, imageBudgetBytes: 10)
expectEqual(ev4.count, 1, "pinned image over budget kept")

// isDuplicate
expect(ClipboardHistory.isDuplicate(.text("a"), .text("a")), "dup text")
expect(!ClipboardHistory.isDuplicate(.text("a"), .text("b")), "not dup text")
expect(ClipboardHistory.isDuplicate(
    .image(.data(Data()), pixelSize: CGSize(width: 1, height: 2), byteCount: 3, hash: "4"),
    .image(.file(URL(fileURLWithPath: "/x.png")), pixelSize: CGSize(width: 1, height: 2),
           byteCount: 3, hash: "4")), "dup image ignores blob")
expect(!ClipboardHistory.isDuplicate(
    .image(.data(Data()), pixelSize: .zero, byteCount: 3, hash: "4"),
    .image(.data(Data()), pixelSize: .zero, byteCount: 3, hash: "5")), "not dup image hash")
let u1 = URL(fileURLWithPath: "/tmp/a")
expect(ClipboardHistory.isDuplicate(.files([u1]), .files([u1])), "dup files")
expect(!ClipboardHistory.isDuplicate(.files([u1]), .files([u1, u1])), "not dup files")

// decode 旧格式 + 新格式往返
let oldJson: [[String: Any]] = [["text": "a", "time": "1.0"]]
let oldItems = ClipboardHistory.decode(oldJson, dir: URL(fileURLWithPath: "/tmp"))
expectEqual(oldItems.count, 1, "legacy decode count")
if case .text(let s) = oldItems.first?.payload { expectEqual(s, "a", "legacy text") }
else { expect(false, "legacy text") }
let srcDir = URL(fileURLWithPath: "/tmp/popbar-clip-test")
let rt = [
    mkItem(.text("hello"), pinned: true),
    mkItem(.image(.file(srcDir.appendingPathComponent("x.png")),
                  pixelSize: CGSize(width: 2, height: 3), byteCount: 9, hash: "7")),
    mkItem(.files([u1])),
]
let rt2 = ClipboardHistory.decode(ClipboardHistory.encode(rt), dir: srcDir)
expectEqual(rt2.count, 3, "roundtrip count")
expect(rt2[0].pinned, "roundtrip pinned")
if case .image(.file(let u), let size, let bytes, let hash) = rt2[1].payload {
    expect(u.lastPathComponent == "x.png" && size == CGSize(width: 2, height: 3)
           && bytes == 9 && hash == "7", "roundtrip image")
} else { expect(false, "roundtrip image") }
if case .files(let urls) = rt2[2].payload {
    expectEqual(urls, [u1], "roundtrip urls")
} else { expect(false, "roundtrip urls") }

// ClipboardHistoryConfig:limit clamp 与缺省回退
let ccfg1 = try! JSONDecoder().decode(ClipboardHistoryConfig.self, from: "{\"limit\":100}".data(using: .utf8)!)
expectEqual(ccfg1.limit, 10, "limit clamp max")
let ccfg0 = try! JSONDecoder().decode(ClipboardHistoryConfig.self, from: "{\"limit\":0}".data(using: .utf8)!)
expectEqual(ccfg0.limit, 1, "limit clamp min")
let ccfgD = try! JSONDecoder().decode(ClipboardHistoryConfig.self, from: "{}".data(using: .utf8)!)
expect(ccfgD.images && ccfgD.files, "images/files default true")
expectEqual(ccfgD.imageSizeMB, 50, "imageSizeMB default")
expectEqual(ccfgD.imageMaxMB, 10, "imageMaxMB default")

// MARK: - 系统监控:进程分组 / 来源判定

section("AppIdentity.bundlePath")
let cursorHelper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"
expectEqual(AppIdentity.bundlePath(forExecutable: cursorHelper), "/Applications/Cursor.app", "嵌套 Helper 归到最外层 App")
expectEqual(AppIdentity.bundlePath(forExecutable: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx"),
            "/Applications/WeChat.app", "WeChat 内嵌 .app 归到 WeChat")
expect(AppIdentity.bundlePath(forExecutable: "/usr/local/bin/python3") == nil, "非 App 路径返回 nil")
expect(AppIdentity.bundlePath(forExecutable: "/opt/homebrew/bin/mysqld") == nil, "homebrew 程序不是 App")
expect(AppIdentity.isMainExecutable("/Applications/Cursor.app/Contents/MacOS/Cursor", bundle: "/Applications/Cursor.app"), "主可执行文件")
expect(!AppIdentity.isMainExecutable(cursorHelper, bundle: "/Applications/Cursor.app"), "Helper 不是主可执行文件")

section("ProcessGrouping")
func prow(_ pid: Int, _ name: String, _ mem: UInt64, _ cpu: Double) -> ProcessRow {
    ProcessRow(pid: pid, name: name, memoryBytes: mem, cpuPercent: cpu, powerScore: cpu)
}
let grows = [prow(300, "Cursor Helper", 500, 1.0), prow(100, "Cursor", 200, 0.5), prow(301, "Cursor Helper (Renderer)", 900, 2.0),
             prow(50, "python3", 70, 0.1), prow(51, "python3", 30, 0.2), prow(7, "mystery", 5, 9.0)]
let gpaths: [Int: String] = [
    300: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper",
    100: "/Applications/Cursor.app/Contents/MacOS/Cursor",
    301: cursorHelper,
    50: "/usr/local/bin/python3", 51: "/usr/local/bin/python3",
]
let groups = ProcessGrouping.group(grows, paths: gpaths)
expectEqual(groups.count, 4, "4 行:Cursor 合并为 1 行,其余 3 个独立进程各 1 行")
let gCursor = groups.first { $0.id == "app:/Applications/Cursor.app" }
expectEqual(gCursor?.count ?? 0, 3, "Cursor 合并 3 个进程")
expectEqual(gCursor?.mainPID ?? 0, 100, "Cursor 主进程取 Contents/MacOS 下的可执行文件")
expectEqual(gCursor?.memoryBytes ?? 0, 1600, "内存求和")
expect(abs((gCursor?.cpuPercent ?? 0) - 3.5) < 1e-9, "CPU 求和")
expectEqual(gCursor?.members.first?.pid ?? 0, 301, "成员按内存降序")
let gPy = groups.filter { $0.name == "python3" }
expectEqual(gPy.count, 2, "同一程序的两个实例各占一行(终止不会连带)")
expect(gPy.allSatisfy { $0.count == 1 }, "非 App 进程组只含自己")
expectEqual(groups.first?.id ?? "", "pid:7", "按能耗(CPU 合计)降序:读不到路径的 mystery(9.0)排第一")
expectEqual(groups.first?.exePath ?? "-", "-", "读不到路径的进程 exePath 为空")

section("ProcessText")
expectEqual(ProcessText.compactDuration(45), "45s", "时长:秒")
expectEqual(ProcessText.compactDuration(3 * 3600 + 7 * 60), "3h 7m", "时长:时分")
expectEqual(ProcessText.compactDuration(2 * 86400 + 5 * 3600), "2d 5h", "时长:天时")
expect(ProcessText.isSystemPath("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"), "系统路径")
expect(!ProcessText.isSystemPath("/Applications/Cursor.app/Contents/MacOS/Cursor"), "非系统路径")

section("ProcessText.classify(来源判定)")
func cn(_ pid: Int, _ name: String, _ app: String? = nil) -> ChainNode { ChainNode(pid: pid, name: name, appName: app) }
let launchd = cn(1, "launchd")
expectEqual(ProcessText.classify(chain: [launchd, cn(45525, "Cursor", "Cursor")], label: nil, hasPlist: false).kind,
            .launchd, "父进程是 launchd")
expectEqual(ProcessText.classify(chain: [launchd, cn(758, "mysqld")], label: "homebrew.mxcl.mysql", hasPlist: true).kind,
            .launchdLabel, "有 plist 的 launchd 服务")
expectEqual(ProcessText.classify(chain: [launchd, cn(10, "sshd"), cn(11, "sshd-session"), cn(12, "zsh"), cn(13, "vim")],
                                 label: nil, hasPlist: false).kind, .ssh, "祖先含 sshd")
let shellChain = [launchd, cn(900, "ghostty", "Ghostty"), cn(901, "login"), cn(902, "zsh"), cn(903, "node")]
let shellInfo = ProcessText.classify(chain: shellChain, label: nil, hasPlist: false)
expectEqual(shellInfo.kind, .shell, "祖先含 shell")
expect(shellInfo.summary.contains("Ghostty"), "终端名取 shell 之上、跳过 login 的那个祖先")
expectEqual(ProcessText.classify(chain: [launchd, cn(5, "Cursor", "Cursor"), cn(6, "node")], label: nil, hasPlist: false).kind,
            .parent, "普通父进程")
expectEqual(ProcessText.classify(chain: [cn(6, "orphan")], label: nil, hasPlist: false).kind, .unknown, "没有任何祖先 → 来源未知")

section("ProcessText.ownership(归属与可信度)")
let appG = ProcessGroup(id: "app:/Applications/Cursor.app", name: "Cursor", appPath: "/Applications/Cursor.app",
                        exePath: nil, mainPID: 1, members: [], memoryBytes: 0, cpuPercent: 0, powerScore: 0)
let exeG = ProcessGroup(id: "pid:2", name: "node", appPath: nil, exePath: "/usr/local/bin/node",
                        mainPID: 2, members: [], memoryBytes: 0, cpuPercent: 0, powerScore: 0)
let oApp = ProcessText.ownership(group: appG, chain: [launchd, cn(1, "Cursor")], source: ProcessText.classify(chain: [launchd, cn(1, "Cursor")], label: nil, hasPlist: false), plistPath: nil)
expectEqual(oApp.confidence, .high, "App 包内 → 高可信度")
expectEqual(oApp.evidence, "/Applications/Cursor.app", "识别依据是 App 路径")
let childChain = [launchd, cn(5, "Cursor", "Cursor"), cn(2, "node")]
let oChild = ProcessText.ownership(group: exeG, chain: childChain, source: ProcessText.classify(chain: childChain, label: nil, hasPlist: false), plistPath: nil)
expectEqual(oChild.confidence, .medium, "祖先是 App 的子进程 → 中可信度")
expectEqual(oChild.owner ?? "", "Cursor", "归属到祖先 App")
let oShell = ProcessText.ownership(group: exeG, chain: shellChain + [cn(2, "node")], source: shellInfo, plistPath: nil)
expectEqual(oShell.confidence, .possible, "经 shell 启动 → 只能说「可能」")
let oPlist = ProcessText.ownership(group: exeG, chain: [launchd, cn(2, "node")], source: ProcessText.classify(chain: [launchd, cn(2, "node")], label: "x", hasPlist: true), plistPath: "/Library/LaunchDaemons/x.plist")
expectEqual(oPlist.confidence, .high, "有 launchd plist → 高可信度")

section("SystemMonitorActions.isProtected")
let selfG = ProcessGroup(id: "pid:self", name: "self", appPath: nil, exePath: nil, mainPID: Int(getpid()),
                         members: [ProcessRow(pid: Int(getpid()), name: "self", memoryBytes: 0, cpuPercent: 0, powerScore: 0)],
                         memoryBytes: 0, cpuPercent: 0, powerScore: 0)
expect(SystemMonitorActions.isProtected(selfG), "不能结束自己")
let initG = ProcessGroup(id: "pid:1", name: "launchd", appPath: nil, exePath: "/sbin/launchd", mainPID: 1,
                         members: [ProcessRow(pid: 1, name: "launchd", memoryBytes: 0, cpuPercent: 0, powerScore: 0)],
                         memoryBytes: 0, cpuPercent: 0, powerScore: 0)
expect(SystemMonitorActions.isProtected(initG), "不能结束 PID 1")

section("LibProc(对当前进程做真实调用)")
let me = Int(getpid())
expect(LibProc.path(me) != nil, "proc_pidpath 能读到自己的路径")
expect(LibProc.startKey(me) != nil, "能读到自己的启动时刻")
expect((LibProc.taskInfo(me)?.pti_threadnum ?? 0) > 0, "线程数 > 0")
expect(LibProc.fdCount(me) > 0, "打开文件数 > 0")
expect(LibProc.cwd(me) != nil, "能读到工作目录")
expect(LibProc.args(me)?.argv.isEmpty == false, "能读到启动参数")
expect(LibProc.parentMap()[me] != nil, "父进程表包含自己")

// 录屏导出管线:合成视频 → 真跑导出 → 抽帧验收(tests/export.swift)
await runExportPipelineTests()
await runCleanTests()

print("\n========== \(checks) 项检查,\(failures) 项失败 ==========")
exit(failures == 0 ? 0 : 1)

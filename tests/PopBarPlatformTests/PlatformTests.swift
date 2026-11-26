import XCTest
import AppKit
@testable import PopBarPlatform

final class ScreenPlacementTests: XCTestCase {
    // 主屏 1440×900（菜单栏 25），右侧副屏 1920×1080（Dock 在底部 70）
    let screens: [(frame: CGRect, visible: CGRect)] = [
        (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875)),
        (CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: 1440, y: 70, width: 1920, height: 1010)),
    ]
    let size = CGSize(width: 300, height: 38)

    func testAbovePreferred() {
        let r = ScreenPlacement.frame(size: size, anchor: CGRect(x: 500, y: 400, width: 100, height: 20), prefer: .above, screens: screens)
        XCTAssertEqual(r.minY, 426)
    }

    func testFlipsBelowNearTop() {
        let r = ScreenPlacement.frame(size: size, anchor: CGRect(x: 500, y: 860, width: 100, height: 14), prefer: .above, screens: screens)
        XCTAssertLessThan(r.maxY, 860)
    }

    func testStaysOnSecondaryScreen() {
        // 副屏右边缘：不能跑回主屏，也不能越出右边
        let r = ScreenPlacement.frame(size: size, anchor: CGRect(x: 3340, y: 500, width: 10, height: 20), prefer: .above, screens: screens)
        XCTAssertGreaterThanOrEqual(r.minX, 1440)
        XCTAssertLessThanOrEqual(r.maxX, 3360)
    }

    func testRespectsVisibleFrameOnSecondary() {
        // 副屏底部（Dock 区域）优先下方时翻到上方，且不压到 Dock
        let r = ScreenPlacement.frame(size: CGSize(width: 460, height: 400), anchor: CGRect(x: 2000, y: 100, width: 100, height: 20), prefer: .below, screens: screens)
        XCTAssertGreaterThanOrEqual(r.minY, 74)
    }

    func testBelowPreferred() {
        let r = ScreenPlacement.frame(size: size, anchor: CGRect(x: 500, y: 400, width: 100, height: 20), prefer: .below, gap: 8, screens: screens)
        XCTAssertEqual(r.maxY, 392)
    }

    func testFitWindowShrinksTallWindowAboveBottomDock() {
        // 复现内置屏（1470×956，底部程序坞高 65，顶部菜单栏高 34）上 984 高度窗口底边跌入程序坞的场景
        let laptop: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 65, width: 1470, height: 857)),
        ]
        let saved = CGRect(x: 238, y: -62, width: 1071, height: 984)
        let fitted = ScreenPlacement.fitWindow(saved, minSize: CGSize(width: 820, height: 520), screens: laptop)
        XCTAssertEqual(fitted, CGRect(x: 238, y: 65, width: 1071, height: 857))
    }

    func testFitWindowLiftsBottomEdgeAboveDock() {
        let laptop: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 65, width: 1470, height: 857)),
        ]
        let overlappingDock = CGRect(x: 200, y: 12, width: 980, height: 660)
        let fitted = ScreenPlacement.fitWindow(overlappingDock, minSize: CGSize(width: 820, height: 520), screens: laptop)
        XCTAssertEqual(fitted, CGRect(x: 200, y: 65, width: 980, height: 660))
    }

    func testFitWindowRespectsSideDock() {
        let leftDock: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 72, y: 0, width: 1398, height: 922)),
        ]
        let fitted = ScreenPlacement.fitWindow(CGRect(x: 10, y: 120, width: 980, height: 660),
                                               minSize: CGSize(width: 820, height: 520), screens: leftDock)
        XCTAssertEqual(fitted, CGRect(x: 72, y: 120, width: 980, height: 660))
    }

    func testFitWindowPreservesValidFrameUnchanged() {
        let laptop: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 65, width: 1470, height: 857)),
        ]
        let valid = CGRect(x: 245, y: 160, width: 980, height: 660)
        let fitted = ScreenPlacement.fitWindow(valid, minSize: CGSize(width: 820, height: 520), screens: laptop)
        XCTAssertEqual(fitted, valid)
    }

    func testFitWindowRecoversOffscreenWindowCentered() {
        let laptop: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 65, width: 1470, height: 857)),
        ]
        // 曾经停在已拔掉的外接屏上
        let disconnected = CGRect(x: 2600, y: 120, width: 1200, height: 960)
        let fitted = ScreenPlacement.fitWindow(disconnected, minSize: CGSize(width: 820, height: 520), screens: laptop)
        XCTAssertGreaterThanOrEqual(fitted.minX, 0)
        XCTAssertLessThanOrEqual(fitted.maxX, 1470)
        XCTAssertGreaterThanOrEqual(fitted.minY, 65)
        XCTAssertLessThanOrEqual(fitted.maxY, 922)
        XCTAssertEqual(fitted.height, 857)
        XCTAssertEqual(fitted.width, 1200)
    }

    func testFitWindowHandlesScreenSmallerThanMinSize() {
        let tiny: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 60, width: 800, height: 500)),
        ]
        let fitted = ScreenPlacement.fitWindow(CGRect(x: 0, y: 0, width: 980, height: 660),
                                               minSize: CGSize(width: 820, height: 520), screens: tiny)
        XCTAssertEqual(fitted, CGRect(x: 0, y: 60, width: 800, height: 500))
    }
}

final class PasteboardSnapshotTests: XCTestCase {
    func testRoundTripAddsTransientMarkers() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        pb.writeObjects([item])

        guard let snap = PasteboardSnapshot.take(pb) else { return XCTFail("snapshot nil") }
        pb.clearContents()
        pb.setString("copied by ⌘C", forType: .string)

        snap.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertEqual(pb.data(forType: NSPasteboard.PasteboardType("com.example.custom")), Data([1, 2, 3]))
        XCTAssertTrue(PasteboardSnapshot.shouldSkipForHistory(pb))
    }

    func testLazyTypesSkipped() {
        XCTAssertTrue(PasteboardSnapshot.isLazyType(NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8y")))
        XCTAssertTrue(PasteboardSnapshot.isLazyType(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
        XCTAssertFalse(PasteboardSnapshot.isLazyType(.string))
    }

    func testConcealedSkippedForHistory() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data(), forType: PasteboardSnapshot.concealedType)
        pb.writeObjects([item])
        XCTAssertTrue(PasteboardSnapshot.shouldSkipForHistory(pb))
    }
}

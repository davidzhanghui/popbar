import XCTest
@testable import PopBarKit

final class RecordEntryTests: XCTestCase {
    /// 旧版 recordings.json 没有 source 字段,必须照常解码为「原始录屏」
    func testDecodesLegacyEntryWithoutSource() throws {
        let json = #"[{"path":"/tmp/a.mov","createdAt":1,"duration":2,"bytes":3,"isGIF":false}]"#
        let list = try JSONDecoder().decode([RecordEntry].self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].source)
        XCTAssertFalse(list[0].isExported)
    }

    func testExportedEntryRoundTrip() throws {
        let e = RecordEntry(path: "/tmp/a-edit.gif", createdAt: 1, duration: 2, bytes: 3,
                            isGIF: true, source: "/tmp/a.mov")
        let back = try JSONDecoder().decode(RecordEntry.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
        XCTAssertTrue(back.isExported)
        // 源文件不存在时不给重新导出的入口
        XCTAssertNil(back.sourceURL)
    }
}

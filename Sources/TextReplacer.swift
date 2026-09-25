import Cocoa
import ApplicationServices

/// 就地替换选中文本(工具条动作专用:焦点没有离开过原 App,
/// 直接 ⌘V,剪贴板先备份后还原)。
enum TextReplacer {

    /// 与原实现一致:备份剪贴板 → 写入新文本 → ⌘V → 0.3s 后还原
    static func replaceInline(_ newText: String) {
        let pb = NSPasteboard.general
        let backup = PasteboardGuard.snapshot(pb)
        PasteboardGuard.write(newText, to: pb)
        Actions.postKeyCombo(key: 9)   // kVK_ANSI_V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            PasteboardGuard.restore(pb, backup)
        }
    }

}

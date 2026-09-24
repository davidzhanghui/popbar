import Cocoa

/// CG/AX 坐标系(左上原点) 与 Cocoa 坐标系(左下原点) 之间的转换
enum Screen {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaPoint(from cg: CGPoint) -> CGPoint {
        CGPoint(x: cg.x, y: primaryHeight - cg.y)
    }

    static func cocoaRect(from axRect: CGRect) -> CGRect {
        CGRect(x: axRect.origin.x,
               y: primaryHeight - axRect.origin.y - axRect.height,
               width: axRect.width,
               height: axRect.height)
    }
}

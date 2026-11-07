import Cocoa
import PopBarCore

extension RGBAColor {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

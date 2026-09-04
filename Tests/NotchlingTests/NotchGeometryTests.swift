import CoreGraphics
import NotchlingKit

enum NotchGeometryTests {
    static func all() {
        Check.run("notched display centres and pins to top") {
            let m = NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                safeAreaTop: 32, auxLeftWidth: 620, auxRightWidth: 620, menuBarHeight: 32)
            let l = NotchGeometry.layout(for: m)
            Check.ok(!l.isSynthetic, "should be a real notch")
            Check.eq(l.notchRect.width, 200, "width = 1440 - 1240")
            Check.eq(l.notchRect.height, 32, "height = safeAreaTop")
            Check.eq(l.notchRect.midX, 720, "centred on screen")
            Check.eq(l.notchRect.maxY, 900, "flush to top edge")
        }

        Check.run("asymmetric aux areas still centre on screen") {
            let m = NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                safeAreaTop: 30, auxLeftWidth: 500, auxRightWidth: 300, menuBarHeight: 30)
            let l = NotchGeometry.layout(for: m)
            Check.eq(l.notchRect.width, 200, "width = 1000 - 800")
            Check.eq(l.notchRect.midX, 500, "screen centre")
        }

        Check.run("global screen origin is respected") {
            let m = NotchMetrics(
                screenFrame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
                safeAreaTop: 32, auxLeftWidth: 656, auxRightWidth: 656, menuBarHeight: 32)
            let l = NotchGeometry.layout(for: m)
            Check.eq(l.notchRect.width, 200, "width")
            Check.eq(l.notchRect.midX, -756, "centre in global space")
            Check.eq(l.notchRect.minX, -856, "left edge in global space")
        }

        Check.run("non-notched fallback pill under the menu bar") {
            let m = NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                safeAreaTop: 0, auxLeftWidth: nil, auxRightWidth: nil, menuBarHeight: 24)
            let l = NotchGeometry.layout(for: m)
            Check.ok(l.isSynthetic, "synthetic pill")
            Check.ok(l.notchRect.size == NotchGeometry.fallbackSize, "fallback size")
            Check.eq(l.notchRect.midX, 640, "centred")
            Check.eq(l.notchRect.maxY, 776, "below menu bar (800 - 24)")
        }

        Check.run("zero safe-area falls back even with aux areas") {
            let m = NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                safeAreaTop: 0, auxLeftWidth: 540, auxRightWidth: 540, menuBarHeight: 24)
            Check.ok(NotchGeometry.layout(for: m).isSynthetic, "no safe area => synthetic")
        }

        Check.run("drop zone grows downward keeping the top edge") {
            let notch = CGRect(x: 620, y: 868, width: 200, height: 32)
            let z = NotchGeometry.dropZoneRect(for: notch)
            Check.eq(z.height, 96, "3x height")
            Check.eq(z.maxY, notch.maxY, "top edge unchanged")
            Check.eq(z.minX, notch.minX, "x unchanged")
            Check.eq(z.width, notch.width, "width unchanged")
        }
    }
}

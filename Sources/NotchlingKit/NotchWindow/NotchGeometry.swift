import CoreGraphics

/// Pure, platform-free description of a screen's notch-relevant metrics.
/// Kept free of AppKit so it is unit-testable with synthetic inputs.
public struct NotchMetrics: Equatable {
    /// Screen frame in global Cocoa coordinates (bottom-left origin).
    public var screenFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`; > 0 only on notched displays.
    public var safeAreaTop: CGFloat
    /// Width of `auxiliaryTopLeftArea`; `nil` on displays without a notch.
    public var auxLeftWidth: CGFloat?
    /// Width of `auxiliaryTopRightArea`; `nil` on displays without a notch.
    public var auxRightWidth: CGFloat?
    /// Menu-bar height (`frame.maxY - visibleFrame.maxY`); used to place the
    /// synthetic pill *under* the menu bar on non-notched Macs.
    public var menuBarHeight: CGFloat

    public init(screenFrame: CGRect,
                safeAreaTop: CGFloat,
                auxLeftWidth: CGFloat?,
                auxRightWidth: CGFloat?,
                menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.safeAreaTop = safeAreaTop
        self.auxLeftWidth = auxLeftWidth
        self.auxRightWidth = auxRightWidth
        self.menuBarHeight = menuBarHeight
    }
}

/// Result of resolving metrics into a concrete on-screen rect.
public struct NotchLayout: Equatable {
    /// Notch rect in global Cocoa coordinates (bottom-left origin).
    public var notchRect: CGRect
    /// `true` when no real notch exists and the synthetic pill is used.
    public var isSynthetic: Bool

    public init(notchRect: CGRect, isSynthetic: Bool) {
        self.notchRect = notchRect
        self.isSynthetic = isSynthetic
    }
}

public enum NotchGeometry {
    /// Fallback pill size for Macs without a physical notch.
    public static let fallbackSize = CGSize(width: 200, height: 32)

    /// How far the drop zone grows below the notch while a drag is armed.
    public static let dropZoneFactor: CGFloat = 3

    /// Resolve metrics into a notch rect.
    ///
    /// Notched: width = `frame.width - (leftArea + rightArea)`, height =
    /// `safeAreaTop`, pinned flush to the top edge and horizontally centred.
    /// Non-notched: a `fallbackSize` pill centred and dropped just under the
    /// menu bar.
    public static func layout(for m: NotchMetrics) -> NotchLayout {
        let f = m.screenFrame

        if let left = m.auxLeftWidth, let right = m.auxRightWidth, m.safeAreaTop > 0 {
            let width = max(0, f.width - (left + right))
            let height = m.safeAreaTop
            let x = f.midX - width / 2
            let y = f.maxY - height // flush to top edge
            return NotchLayout(
                notchRect: CGRect(x: x, y: y, width: width, height: height),
                isSynthetic: false
            )
        }

        // Synthetic pill, centred under the menu bar.
        let width = fallbackSize.width
        let height = fallbackSize.height
        let x = f.midX - width / 2
        let y = f.maxY - m.menuBarHeight - height
        return NotchLayout(
            notchRect: CGRect(x: x, y: y, width: width, height: height),
            isSynthetic: true
        )
    }

    /// The forgiving drop target: the notch grown downward by `factor`,
    /// keeping the same top edge, x-origin and width.
    public static func dropZoneRect(for notch: CGRect,
                                    factor: CGFloat = dropZoneFactor) -> CGRect {
        let height = notch.height * factor
        return CGRect(x: notch.minX,
                      y: notch.maxY - height,
                      width: notch.width,
                      height: height)
    }
}

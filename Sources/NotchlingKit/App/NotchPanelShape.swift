import SwiftUI

/// One continuous black silhouette that *grows out of* the physical notch:
/// flush to the top edge, exactly the notch width for the first `notchHeight`
/// points (so it merges with the cutout — no seam, no gap), then flares out to
/// the full body width using **concave** fillets at the junction (the hallmark
/// that makes it look molded onto the notch rather than pasted below it), with
/// convex rounded bottom corners.
///
/// When the body is no wider than the notch it degrades to a plain nook
/// (square top, rounded bottom).
struct NotchPanelShape: Shape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var junction: CGFloat = 10   // concave fillet where the body meets the notch
    var bottom: CGFloat = 16     // convex bottom corners
    var flareTop: CGFloat = 9    // convex corners at the body's top-outer edges

    func path(in rect: CGRect) -> Path {
        // SwiftUI's sizing passes can propose infinite/zero rects; producing
        // inf/NaN coordinates here makes CoreGraphics abort the process.
        guard rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return Path() }
        var p = Path()
        let W = rect.width, H = rect.height
        let nH = min(notchHeight, H)
        let nW = min(notchWidth, W)
        let flare = (W - nW) / 2

        // No room to flare → simple nook.
        if flare <= 0.5 {
            let b = min(bottom, H - nH, W / 2)
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: W, y: 0))
            p.addLine(to: CGPoint(x: W, y: H - b))
            p.addQuadCurve(to: CGPoint(x: W - b, y: H), control: CGPoint(x: W, y: H))
            p.addLine(to: CGPoint(x: b, y: H))
            p.addQuadCurve(to: CGPoint(x: 0, y: H - b), control: CGPoint(x: 0, y: H))
            p.closeSubpath()
            return p
        }

        let nL = flare, nR = W - flare
        let r = min(junction, flare, nH)              // concave fillet
        let ft = min(flareTop, max(0, flare - r), (H - nH) / 2)
        let b = min(bottom, W / 2, (H - nH))

        p.move(to: CGPoint(x: nL, y: 0))
        p.addLine(to: CGPoint(x: nR, y: 0))                          // notch top
        p.addLine(to: CGPoint(x: nR, y: nH - r))                     // notch right, down
        p.addQuadCurve(to: CGPoint(x: nR + r, y: nH),                // concave junction
                       control: CGPoint(x: nR, y: nH))
        p.addLine(to: CGPoint(x: W - ft, y: nH))                     // body top-right
        p.addQuadCurve(to: CGPoint(x: W, y: nH + ft),                // convex top-right
                       control: CGPoint(x: W, y: nH))
        p.addLine(to: CGPoint(x: W, y: H - b))                       // body right, down
        p.addQuadCurve(to: CGPoint(x: W - b, y: H), control: CGPoint(x: W, y: H))
        p.addLine(to: CGPoint(x: b, y: H))                           // bottom
        p.addQuadCurve(to: CGPoint(x: 0, y: H - b), control: CGPoint(x: 0, y: H))
        p.addLine(to: CGPoint(x: 0, y: nH + ft))                     // body left, up
        p.addQuadCurve(to: CGPoint(x: ft, y: nH),                    // convex top-left
                       control: CGPoint(x: 0, y: nH))
        p.addLine(to: CGPoint(x: nL - r, y: nH))                     // body top-left
        p.addQuadCurve(to: CGPoint(x: nL, y: nH - r),                // concave junction
                       control: CGPoint(x: nL, y: nH))
        p.addLine(to: CGPoint(x: nL, y: 0))                          // notch left, up
        p.closeSubpath()
        return p
    }
}

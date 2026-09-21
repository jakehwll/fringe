import SwiftUI

/// The notch silhouette: flush against the top of the screen, rounded at the
/// bottom, with concave corners at the top that flare outwards so the body melts
/// into the screen edge.
///
/// The shape draws a body of `bodySize` centred along the top edge of whatever
/// rect it is given, rather than filling that rect. Animating the body size
/// through the path — instead of through a view frame — is what keeps the notch
/// welded to the top of the screen: `rect.minY` is the top edge on every single
/// frame, so there is no origin for SwiftUI to interpolate and overshoot.
struct NotchShape: Shape {
    var bodySize: CGSize
    var flareRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(bodySize.width, bodySize.height), bottomRadius) }
        set {
            bodySize.width = newValue.first.first
            bodySize.height = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let flare = max(0, flareRadius)
        let width = max(0, min(bodySize.width, rect.width - flare * 2))
        let height = max(0, min(bodySize.height, rect.height))
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        let bottom = max(0, min(bottomRadius, min(body.width / 2, body.height)))

        var path = Path()
        path.move(to: CGPoint(x: body.minX - flare, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.minY + flare),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + bottom, y: body.maxY),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.maxY - bottom),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX + flare, y: body.minY),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }
}

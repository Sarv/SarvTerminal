import SwiftUI

/// SarvTerminal's AI agent mark: a robot head with an antenna, drawn as a
/// line glyph. SF Symbols has no robot face, so it is drawn here and
/// follows the foreground style like a symbol does.
struct AIAgentGlyph: View {
    var body: some View {
        AIAgentShape()
            .stroke(.foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// The robot head's outline in a unit square, scaled to the rect.
struct AIAgentShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: width * side, height: height * side))
        }

        var path = Path()
        // Head.
        path.addRoundedRect(in: box(0.18, 0.3, 0.64, 0.6), cornerSize: CGSize(width: 0.16 * side, height: 0.16 * side))
        // Ears.
        path.addRoundedRect(in: box(0.06, 0.5, 0.12, 0.2), cornerSize: CGSize(width: 0.05 * side, height: 0.05 * side))
        path.addRoundedRect(in: box(0.82, 0.5, 0.12, 0.2), cornerSize: CGSize(width: 0.05 * side, height: 0.05 * side))
        // Antenna.
        path.move(to: point(0.5, 0.3))
        path.addLine(to: point(0.5, 0.18))
        path.addEllipse(in: box(0.43, 0.04, 0.14, 0.14))
        // Eyes.
        path.addEllipse(in: box(0.32, 0.46, 0.12, 0.12))
        path.addEllipse(in: box(0.56, 0.46, 0.12, 0.12))
        // Smile.
        path.move(to: point(0.38, 0.7))
        path.addQuadCurve(to: point(0.62, 0.7), control: point(0.5, 0.82))
        return path
    }
}

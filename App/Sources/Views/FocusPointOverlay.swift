import SwiftUI

/// The camera's AF area on the photo, drawn as a viewfinder draws it: corner
/// marks, green where the camera found focus and red where it didn't (white
/// when the camera doesn't say). `corners` are in this view's points, in
/// order round the area, so a rotated or straightened photo turns them too.
struct FocusPointOverlay: View {
    let corners: [CGPoint]
    let inFocus: Bool?

    var body: some View {
        Canvas { ctx, _ in
            guard corners.count == 4 else { return }
            let path = Path { p in
                for i in 0..<4 {
                    let c = corners[i], next = corners[(i + 1) % 4], prev = corners[(i + 3) % 4]
                    // each mark runs a quarter of the way along both sides, at least 6 points
                    func toward(_ q: CGPoint) -> CGPoint {
                        let len = hypot(q.x - c.x, q.y - c.y)
                        let k = len > 0 ? min(max(len / 4, 6), len / 2) / len : 0
                        return CGPoint(x: c.x + (q.x - c.x) * k, y: c.y + (q.y - c.y) * k)
                    }
                    p.move(to: toward(prev))
                    p.addLine(to: c)
                    p.addLine(to: toward(next))
                }
            }
            // dark under the colour, so it shows on any photo
            ctx.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }

    private var colour: Color {
        switch inFocus {
        case true?: .green
        case false?: .red
        case nil: .white
        }
    }
}

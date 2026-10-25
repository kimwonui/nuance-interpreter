import SwiftUI

/// Draws a language's decorative flag style into a rect (used by the orb and the split-screen halves).
/// `phase` drives the waving motion, `angle` the turning motion (taegeuk, emblems).
enum FlagPainter {
    static func paint(_ art: FlagArt, in gc: inout GraphicsContext, rect: CGRect, phase: Double, angle: Double, wave: Double = 4) {
        switch art {
        case .usa: usa(&gc, rect, phase, wave)
        case .korea: korea(&gc, rect, angle)
        case .stripes(let vertical, let bands, let emblem): stripes(&gc, rect, vertical, bands, emblem, phase, angle, wave)
        }
    }

    private static func color(_ hex: UInt32) -> Color { Color(UIColor(hex: hex)) }

    private static func usa(_ gc: inout GraphicsContext, _ box: CGRect, _ phase: Double, _ wave: Double) {
        let red = color(0xB22234), blue = color(0x3C3B6E)
        let h = box.height / 7
        for i in 0..<7 {
            let dy = wave * sin(phase + Double(i) * 0.7)
            gc.fill(Path(CGRect(x: box.minX, y: box.minY + Double(i) * h + dy, width: box.width, height: h + 1)), with: .color(i % 2 == 0 ? red : .white))
        }
        let canton = CGRect(x: box.minX, y: box.minY + wave * sin(phase), width: box.width * 0.45, height: h * 4)
        gc.fill(Path(canton), with: .color(blue))
        let dot = max(3, box.width * 0.018)
        for row in 0..<3 {
            for col in 0..<4 {
                let p = CGPoint(x: canton.minX + canton.width * (0.18 + 0.21 * Double(col)), y: canton.minY + canton.height * (0.25 + 0.25 * Double(row)))
                gc.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)), with: .color(.white))
            }
        }
    }

    private static func korea(_ gc: inout GraphicsContext, _ box: CGRect, _ angle: Double) {
        let red = color(0xCD2E3A), blue = color(0x0047A0)
        gc.fill(Path(box), with: .color(.white))
        let c = CGPoint(x: box.midX, y: box.midY)
        let r = min(box.width, box.height) * 0.22
        var t = gc
        t.translateBy(x: c.x, y: c.y)
        t.rotate(by: .radians(angle))
        t.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(blue))
        var top = Path()
        top.addArc(center: .zero, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        top.closeSubpath()
        t.fill(top, with: .color(red))
        t.fill(Path(ellipseIn: CGRect(x: -r, y: -r / 2, width: r, height: r)), with: .color(red))
        t.fill(Path(ellipseIn: CGRect(x: 0, y: -r / 2, width: r, height: r)), with: .color(blue))
        let bar = min(box.width, box.height) * 0.1
        for k in 0..<4 {
            var b = gc
            b.translateBy(x: c.x, y: c.y)
            b.rotate(by: .degrees(45 + Double(k) * 90))
            for j in 0..<3 {
                b.fill(Path(roundedRect: CGRect(x: r * 1.45 + Double(j) * bar * 0.32, y: -bar / 2, width: bar * 0.18, height: bar), cornerRadius: 1), with: .color(Color(white: 0.12)))
            }
        }
    }

    private static func stripes(_ gc: inout GraphicsContext, _ box: CGRect, _ vertical: Bool, _ bands: [(UInt32, Int)], _ emblem: FlagArt.Emblem?, _ phase: Double, _ angle: Double, _ wave: Double) {
        let total = Double(bands.reduce(0) { $0 + $1.1 })
        var offset = 0.0
        for (i, band) in bands.enumerated() {
            let share = Double(band.1) / total
            let shift = wave * sin(phase + Double(i) * 0.9)
            let r = vertical
                ? CGRect(x: box.minX + box.width * offset + shift, y: box.minY, width: box.width * share + 1, height: box.height)
                : CGRect(x: box.minX, y: box.minY + box.height * offset + shift, width: box.width, height: box.height * share + 1)
            gc.fill(Path(r), with: .color(color(band.0)))
            offset += share
        }
        guard let emblem else { return }
        let c = CGPoint(x: box.midX, y: box.midY)
        let s = min(box.width, box.height)
        switch emblem {
        case .disc(let hex, let ratio):
            let r = s * ratio
            gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color(hex)))
        case .star(let hex):
            gc.fill(star(center: c, radius: s * 0.2, rotation: angle * 0.2), with: .color(color(hex)))
        case .ring(let hex, let ratio):
            let r = s * ratio
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color(hex)), lineWidth: max(1.5, r * 0.15))
            var spokes = gc
            spokes.translateBy(x: c.x, y: c.y)
            spokes.rotate(by: .radians(angle * 0.3))
            var p = Path()
            for k in 0..<12 {
                let a = Double(k) * .pi / 6
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: r * cos(a), y: r * sin(a)))
            }
            spokes.stroke(p, with: .color(color(hex)), lineWidth: max(0.8, r * 0.05))
        }
    }

    private static func star(center c: CGPoint, radius R: Double, rotation: Double) -> Path {
        var p = Path()
        for i in 0..<10 {
            let r = i % 2 == 0 ? R : R * 0.4
            let a = -Double.pi / 2 + Double(i) * .pi / 5 + rotation
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

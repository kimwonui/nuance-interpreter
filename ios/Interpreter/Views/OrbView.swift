import SwiftUI

/// Center orb. Motion numbers follow the Figma "Orb motion spec" (node 9:37) plus the speaking styles below.
/// - idle: slow breathing (mic off)
/// - listening: follows the real mic level (only shown while the mic is actually live)
/// - holding: NUA's voice is buffered until the speaker pauses — slow orbiting dashes, no level reaction
/// - processing: rotating angular gradient + orbit dots (connecting)
/// - speaking(lang): follows the real playback level. English = stripes-and-canton style with a waving
///   motion; Korean = taegeuk style with a turning motion; nil = neutral gradient. Flags are a visual cue
///   for the output language only — the status text always says it in words.
/// - disabled: static grey (stopped, error, no permission, muted) — never pretends to listen
struct OrbView: View {
    enum Mode: Equatable { case idle, listening, holding, processing, speaking(Lang?), disabled }

    let mode: Mode
    let inputLevel: Float
    let outputLevel: Float
    var accessibilityText: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var driver = OrbDriver()

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: mode == .disabled && driver.settled)) { tl in
                Canvas { gc, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let f = driver.step(t: t, mode: mode, input: inputLevel, output: outputLevel, reduce: reduceMotion)
                    draw(&gc, size: size, f: f)
                }
            }
            if mode == .disabled {
                Image(systemName: "mic.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .frame(width: 320, height: 320)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Drawing

    private func draw(_ gc: inout GraphicsContext, size: CGSize, f: OrbDriver.Frame) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = 95 * f.scale
        let stops = scheme == .dark ? [0xFF6E33, 0xFF4A66, 0xFF4090] : [0xFF5A1E, 0xF8324E, 0xF0276A]
        let colors = stops.map { Color(UIColor(hex: UInt32($0))) }
        let linear = Gradient(stops: [.init(color: colors[0], location: 0), .init(color: colors[1], location: 0.62), .init(color: colors[2], location: 1)])
        let tl = CGPoint(x: c.x - R, y: c.y - R), br = CGPoint(x: c.x + R, y: c.y + R)
        let color = 1 - f.grey
        let usRed = Color(UIColor(hex: 0xB22234)), usBlue = Color(UIColor(hex: 0x3C3B6E))
        let krRed = Color(UIColor(hex: 0xCD2E3A)), krBlue = Color(UIColor(hex: 0x0047A0))

        // Glow (tinted toward the output language while speaking)
        if f.glow * color > 0.01 {
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 40))
                layer.opacity = f.glow * color
                let r = R * 1.02
                let rect = CGRect(x: c.x - r, y: c.y - r + 12, width: r * 2, height: r * 2)
                layer.fill(Path(ellipseIn: rect), with: .linearGradient(linear, startPoint: tl, endPoint: br))
                if f.en > 0.01 { var l = layer; l.opacity = f.en; l.fill(Path(ellipseIn: rect), with: .color(usBlue)) }
                if f.ko > 0.01 { var l = layer; l.opacity = f.ko; l.fill(Path(ellipseIn: rect), with: .color(krBlue)) }
            }
        }
        // Listening rings (mic level)
        for (k, op) in [(1.16, 0.22), (1.3, 0.1)] where f.rings > 0.01 {
            let r = R * k
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Theme.accent.opacity(op * f.rings * 2.2)), lineWidth: 2)
        }
        // Holding: dashed ring orbiting slowly (waiting for the pause)
        if f.hold > 0.01 {
            let r = R * 1.2
            var ring = Path()
            ring.addArc(center: c, radius: r, startAngle: .radians(f.holdAngle), endAngle: .radians(f.holdAngle + 2 * .pi), clockwise: false)
            gc.stroke(ring, with: .color(Theme.accent.opacity(0.45 * f.hold)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 10]))
        }
        // Output ripples (playback level)
        let rippleColor = f.en > 0.5 ? usBlue : f.ko > 0.5 ? krBlue : Theme.accent
        for p in f.ripples {
            let r = R * (1 + 0.5 * p)
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(rippleColor.opacity(0.35 * (1 - p) * f.rippleAlpha)), lineWidth: 2)
        }

        let body = blob(center: c, radius: R, amp: f.amp, phase: f.wobblePhase)
        if f.grey > 0.99 {
            gc.fill(body, with: .color(Theme.selected))
            return
        }
        // Base gradient body
        let base = max(0, 1 - f.en - f.ko)
        if base > 0.01 {
            var g = gc
            g.opacity = f.bodyOpacity * base
            if f.angular > 0.01 {
                g.fill(body, with: .conicGradient(Gradient(colors: [colors[0], colors[1], colors[2], colors[0]]), center: c, angle: .radians(f.rotation)))
            } else {
                g.fill(body, with: .linearGradient(linear, startPoint: tl, endPoint: br))
            }
        }
        // English style: red/white stripes that wave + blue canton with stars
        if f.en > 0.01 {
            gc.drawLayer { layer in
                layer.opacity = f.en
                layer.clip(to: body)
                let box = CGRect(x: c.x - R * 1.15, y: c.y - R * 1.15, width: R * 2.3, height: R * 2.3)
                let h = box.height / 7
                for i in 0..<7 {
                    let dy = 4 * sin(f.flagPhase + Double(i) * 0.7)
                    layer.fill(Path(CGRect(x: box.minX, y: box.minY + Double(i) * h + dy, width: box.width, height: h + 1)), with: .color(i % 2 == 0 ? usRed : .white))
                }
                let canton = CGRect(x: box.minX, y: box.minY + 4 * sin(f.flagPhase), width: box.width * 0.5, height: h * 4)
                layer.fill(Path(canton), with: .color(usBlue))
                for row in 0..<3 {
                    for col in 0..<4 {
                        let p = CGPoint(x: canton.minX + canton.width * (0.2 + 0.2 * Double(col)) + R * 0.12, y: canton.minY + canton.height * (0.25 + 0.25 * Double(row)))
                        layer.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
                    }
                }
            }
        }
        // Korean style: white body, turning red/blue taegeuk, four bar marks
        if f.ko > 0.01 {
            gc.drawLayer { layer in
                layer.opacity = f.ko
                layer.fill(body, with: .color(.white))
                layer.stroke(body, with: .color(Theme.selected), lineWidth: 1.5)
                let r = R * 0.5
                var t = layer
                t.translateBy(x: c.x, y: c.y)
                t.rotate(by: .radians(f.taegeukAngle))
                t.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(krBlue))
                var top = Path()
                top.addArc(center: .zero, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                top.closeSubpath()
                t.fill(top, with: .color(krRed))
                t.fill(Path(ellipseIn: CGRect(x: -r, y: -r / 2, width: r, height: r)), with: .color(krRed))
                t.fill(Path(ellipseIn: CGRect(x: 0, y: -r / 2, width: r, height: r)), with: .color(krBlue))
                // trigram-like bar groups at the four diagonals
                for k in 0..<4 {
                    var b = layer
                    b.translateBy(x: c.x, y: c.y)
                    b.rotate(by: .degrees(45 + Double(k) * 90))
                    for j in 0..<3 {
                        b.fill(Path(roundedRect: CGRect(x: R * 0.68 + Double(j) * 7, y: -11, width: 4, height: 22), cornerRadius: 1), with: .color(Color(white: 0.12)))
                    }
                }
            }
        }
        // Highlight
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 26))
            layer.opacity = 0.3 * color
            let hr = R * 0.55
            layer.fill(Path(ellipseIn: CGRect(x: c.x - R * 0.75, y: c.y - R * 0.85, width: hr * 2, height: hr * 2)), with: .color(.white))
        }
        // Processing orbit dots
        if f.dots > 0.01 {
            for k in 0..<3 {
                let a = f.rotation * (2.4 / 1.8) + Double(k) * 2.1
                let p = CGPoint(x: c.x + R * 1.18 * cos(a), y: c.y + R * 1.18 * sin(a))
                gc.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.accent.opacity(0.6 * f.dots)))
            }
        }
    }

    private func blob(center c: CGPoint, radius R: Double, amp: Double, phase w: Double) -> Path {
        var path = Path()
        let n = 120
        for i in 0...n {
            let th = Double(i) / Double(n) * 2 * .pi
            let wobble = 0.5 * sin(3 * th + w) + 0.3 * sin(5 * th - 1.3 * w + 1.7) + 0.2 * sin(7 * th + 0.7 * w + 2.3)
            let r = R * (1 + amp * wobble)
            let p = CGPoint(x: c.x + r * cos(th), y: c.y + r * sin(th))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// Eases every visual parameter toward the current mode's target (state changes take ~250 ms).
final class OrbDriver {
    struct Frame {
        var scale = 1.0, amp = 0.0, glow = 0.22, bodyOpacity = 0.92, rings = 0.0
        var angular = 0.0, dots = 0.0, grey = 0.0, rippleAlpha = 0.0, hold = 0.0, en = 0.0, ko = 0.0
        var rotation = 0.0, wobblePhase = 0.0, holdAngle = 0.0, flagPhase = 0.0, taegeukAngle = 0.0
        var ripples: [Double] = []
    }

    private var last: Double?
    private var cur = Frame()
    private var v: Double = 0
    private var rotation = 0.0, wobble = 0.0, holdAngle = 0.0, flagPhase = 0.0, taegeuk = -0.5
    private var rippleStarts: [Double] = []
    private var lastRipple = 0.0
    private(set) var settled = false

    func step(t: Double, mode: OrbView.Mode, input: Float, output: Float, reduce: Bool) -> Frame {
        let dt = min(0.05, max(0, t - (last ?? t)))
        last = t

        var speakingLang: Lang?? = nil // .some(nil) = neutral speaking
        if case .speaking(let l) = mode { speakingLang = .some(l) }
        let isSpeaking = speakingLang != nil

        // Level smoothing: rise 60 ms, fall 250 ms (real mic level while listening, real playback level while speaking)
        let raw: Double = mode == .listening ? Double(input) : isSpeaking ? Double(output) : 0
        let target = min(1, max(0, raw * 9))
        v += (target - v) * min(1, dt / (target > v ? 0.06 : 0.25))

        var goal = Frame()
        switch mode {
        case .idle:
            goal.scale = reduce ? 1 : 1.02 + 0.02 * sin(2 * .pi * t / 4.0)
        case .listening:
            goal.scale = reduce ? 1 + 0.06 * v : 1.08 + 0.18 * v
            goal.amp = reduce ? 0 : 0.02 + 0.08 * v
            goal.glow = 0.5; goal.bodyOpacity = 1
            goal.rings = reduce ? 0 : 0.1 + 0.3 * v
        case .holding:
            goal.scale = 1.0
            goal.glow = 0.3; goal.bodyOpacity = 1
            goal.hold = 1
        case .processing:
            goal.scale = reduce ? 1.02 : 1.02 + 0.015 * sin(2 * .pi * t / 1.2)
            goal.amp = reduce ? 0 : 0.025
            goal.glow = 0.32; goal.bodyOpacity = 1
            goal.angular = 1; goal.dots = reduce ? 0 : 1
        case .speaking(let lang):
            goal.scale = reduce ? 1 + 0.06 * v : 1.05 + 0.15 * v
            goal.amp = reduce ? 0 : (lang == nil ? 0.015 + 0.06 * v : 0.01 + 0.03 * v)
            goal.glow = 0.45; goal.bodyOpacity = 1
            goal.rippleAlpha = 1
            goal.en = lang == .en ? 1 : 0
            goal.ko = lang == .ko ? 1 : 0
        case .disabled:
            goal.scale = 0.96; goal.glow = 0; goal.bodyOpacity = 1; goal.grey = 1
        }

        let k = min(1, dt / 0.25)
        func ease(_ a: inout Double, _ b: Double) { a += (b - a) * k }
        ease(&cur.scale, goal.scale); ease(&cur.amp, goal.amp); ease(&cur.glow, goal.glow)
        ease(&cur.bodyOpacity, goal.bodyOpacity); ease(&cur.rings, goal.rings)
        ease(&cur.angular, goal.angular); ease(&cur.dots, goal.dots); ease(&cur.grey, goal.grey)
        ease(&cur.rippleAlpha, goal.rippleAlpha); ease(&cur.hold, goal.hold)
        ease(&cur.en, goal.en); ease(&cur.ko, goal.ko)
        settled = mode == .disabled && abs(cur.grey - 1) < 0.01 && abs(cur.scale - 0.96) < 0.002

        if !reduce {
            if mode == .processing { rotation += dt * 2 * .pi / 2.4 }
            if mode != .disabled && mode != .holding { wobble += dt * 1.6 }
            if mode == .holding { holdAngle += dt * 2 * .pi / 3.0 }
            if speakingLang == .some(.en) { flagPhase += dt * 2 * .pi / 1.2 }   // waving stripes
            if speakingLang == .some(.ko) { taegeuk += dt * 2 * .pi / 6.0 }     // turning taegeuk
            if isSpeaking, v > 0.05, t - lastRipple > 0.6 { rippleStarts.append(t); lastRipple = t }
        }
        rippleStarts.removeAll { t - $0 > 1.4 }
        cur.rotation = rotation
        cur.wobblePhase = wobble
        cur.holdAngle = holdAngle
        cur.flagPhase = flagPhase
        cur.taegeukAngle = taegeuk
        cur.ripples = rippleStarts.map { (t - $0) / 1.4 }
        return cur
    }
}

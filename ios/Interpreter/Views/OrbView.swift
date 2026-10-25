import SwiftUI

/// Center orb, in the style of a voice-assistant sphere: a steady round orb whose inside is soft light and color
/// clouds that blend and drift all the time. Breathing and level reactions are kept small; the inner flow is
/// what shows it's alive. NUA's coral palette.
/// - idle: calm, slower flow (mic off, tap to start)
/// - listening: livelier flow; size and rings follow the real mic level only (the flow never reacts to sound)
/// - holding: NUA's voice is buffered until the speaker pauses — slow orbiting dashes, no level reaction
/// - processing: faster flow + rotating gradient, sweeping arc and orbit dots (connecting)
/// - speaking(lang): follows the real playback level, styled with the output language's decorative flag
///   (English: waving stripes; Korean: turning taegeuk; others: waving bands/emblems); nil = neutral clouds.
///   Flags are a visual cue for the output language only — the status text names it in words.
/// - disabled: static grey (error, no permission, muted) — never pretends to listen
/// Reduce Motion: the clouds stand still and the orb doesn't scale; state cues stay (arc, rings, dashes).
struct OrbView: View {
    enum Mode: Equatable { case idle, listening, holding, processing, speaking(Lang?), disabled }

    let mode: Mode
    let inputLevel: Float
    let outputLevel: Float
    var accessibilityText: String = ""
    var diameter: CGFloat = 320

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var driver = OrbDriver()

    var body: some View {
        ZStack {
            // The canvas is twice the orb's size so the blurred glow and highlight fade out completely instead of
            // being cut off at a square edge. Layout and the tap area stay the orb's own size.
            TimelineView(.animation(paused: mode == .disabled && driver.settled)) { tl in
                Canvas { gc, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let f = driver.step(t: t, mode: mode, input: inputLevel, output: outputLevel, reduce: reduceMotion)
                    draw(&gc, size: size, f: f)
                }
            }
            .frame(width: diameter * 2, height: diameter * 2)
            .allowsHitTesting(false) // the overflow must not block the language buttons around the orb
            if mode == .disabled {
                Image(systemName: "mic.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Drawing

    /// Soft color clouds inside the orb: (color, size × R, drift speed x, drift speed y, phase offset).
    /// Unrelated speeds make them pass through and blend into each other without a visible loop.
    private static let clouds: [(UInt32, Double, Double, Double, Double)] = [
        (0xFFB27A, 0.78, 0.53, 0.37, 0.0),   // peach
        (0xFF6F95, 0.70, -0.41, 0.59, 2.1),  // pink
        (0xE8344E, 0.80, 0.29, -0.47, 4.2),  // deep coral
        (0xFFFFFF, 0.55, -0.61, -0.33, 1.3), // light
        (0xFF8A5C, 0.60, 0.67, 0.23, 5.1),   // orange
    ]

    private func draw(_ gc: inout GraphicsContext, size: CGSize, f: OrbDriver.Frame) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = 95 * f.scale * Double(diameter / 320)
        let stops = scheme == .dark ? [0xFF6E33, 0xFF4A66, 0xFF4090] : [0xFF5A1E, 0xF8324E, 0xF0276A]
        let colors = stops.map { Color(UIColor(hex: UInt32($0))) }
        let linear = Gradient(stops: [.init(color: colors[0], location: 0), .init(color: colors[1], location: 0.62), .init(color: colors[2], location: 1)])
        let tl = CGPoint(x: c.x - R, y: c.y - R), br = CGPoint(x: c.x + R, y: c.y + R)
        let color = 1 - f.grey

        // Glow
        if f.glow * color > 0.01 {
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 40))
                layer.opacity = f.glow * color
                let r = R * 1.02
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r + 12, width: r * 2, height: r * 2)), with: .linearGradient(linear, startPoint: tl, endPoint: br))
            }
        }
        // Listening rings (real mic level only)
        for (k, op) in [(1.14, 0.22), (1.26, 0.1)] where f.rings > 0.01 {
            let r = R * k
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Theme.accent.opacity(op * f.rings * 2.2)), lineWidth: 2)
        }
        // Connecting: a bright arc sweeping around the orb
        if f.sweep > 0.01 {
            let r = R * 1.2
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .radians(f.sweepAngle), endAngle: .radians(f.sweepAngle + 1.3), clockwise: false)
            gc.stroke(arc, with: .color(Theme.accent.opacity(0.7 * f.sweep)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // Holding: dashed ring orbiting slowly (waiting for the pause)
        if f.hold > 0.01 {
            let r = R * 1.2
            var ring = Path()
            ring.addArc(center: c, radius: r, startAngle: .radians(f.holdAngle), endAngle: .radians(f.holdAngle + 2 * .pi), clockwise: false)
            gc.stroke(ring, with: .color(Theme.accent.opacity(0.45 * f.hold)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 10]))
        }
        // Output ripples (real playback level)
        for p in f.ripples {
            let r = R * (1 + 0.4 * p)
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Theme.accent.opacity(0.3 * (1 - p) * f.rippleAlpha)), lineWidth: 2)
        }

        let body = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        if f.grey > 0.99 {
            gc.fill(body, with: .color(Theme.selected))
            return
        }
        // Base gradient (rotating while connecting)
        let base = max(0, 1 - f.flag)
        if base > 0.01 {
            var g = gc
            g.opacity = f.bodyOpacity * base
            if f.angular > 0.01 {
                g.fill(body, with: .conicGradient(Gradient(colors: [colors[0], colors[1], colors[2], colors[0]]), center: c, angle: .radians(f.rotation)))
            } else {
                g.fill(body, with: .linearGradient(linear, startPoint: tl, endPoint: br))
            }
        }
        // Inner clouds: large, very soft blobs drifting and blending (decorative; never driven by the mic)
        if f.flow > 0.01, base > 0.01 {
            gc.drawLayer { layer in
                layer.clip(to: body)
                layer.addFilter(.blur(radius: R * 0.38))
                layer.opacity = f.flow * base * color
                for (hex, size, sx, sy, off) in Self.clouds {
                    let p = CGPoint(x: c.x + R * 0.5 * sin(f.flowPhase * sx + off),
                                    y: c.y + R * 0.5 * cos(f.flowPhase * sy + off * 1.3))
                    let r = R * size * (1 + 0.12 * sin(f.flowPhase * 0.7 + off)) // clouds swell and thin as they drift
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(Color(UIColor(hex: hex)).opacity(hex == 0xFFFFFF ? 0.6 : 0.85)))
                }
            }
        }
        // Output-language flag style (decorative cue; the status text names the language)
        if f.flag > 0.01, let lang = f.flagLang {
            gc.drawLayer { layer in
                layer.opacity = f.flag
                layer.clip(to: body)
                let box = CGRect(x: c.x - R * 1.15, y: c.y - R * 1.15, width: R * 2.3, height: R * 2.3)
                FlagPainter.paint(lang.flag, in: &layer, rect: box, phase: f.flagPhase, angle: f.flagAngle, wave: 4 * Double(diameter / 320))
            }
            if case .korea = lang.flag { gc.stroke(body, with: .color(Theme.selected.opacity(f.flag)), lineWidth: 1.5) }
        }
        // Soft sphere light: gentle highlight upper-left, a little depth lower-right
        gc.drawLayer { layer in
            layer.clip(to: body)
            layer.opacity = 0.22 * color * base
            layer.fill(body, with: .radialGradient(Gradient(colors: [.clear, .clear, Color(UIColor(hex: 0xB0153E)).opacity(0.5)]),
                                                   center: CGPoint(x: c.x - R * 0.25, y: c.y - R * 0.3), startRadius: 0, endRadius: R * 1.3))
        }
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: 24 * Double(diameter / 320) + 4))
            layer.opacity = 0.3 * color
            let hr = R * 0.5
            layer.fill(Path(ellipseIn: CGRect(x: c.x - R * 0.72, y: c.y - R * 0.8, width: hr * 2, height: hr * 1.7)), with: .color(.white))
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
}

/// Eases every visual parameter toward the current mode's target (state changes take ~250 ms).
final class OrbDriver {
    struct Frame {
        var scale = 1.0, glow = 0.22, bodyOpacity = 0.92, rings = 0.0
        var angular = 0.0, dots = 0.0, grey = 0.0, rippleAlpha = 0.0, hold = 0.0, flag = 0.0
        var flow = 0.0, sweep = 0.0
        var flagLang: Lang?
        var rotation = 0.0, holdAngle = 0.0, flagPhase = 0.0, flagAngle = 0.0, flowPhase = 0.0, sweepAngle = 0.0
        var ripples: [Double] = []
    }

    private var last: Double?
    private var cur = Frame()
    private var v: Double = 0
    private var rotation = 0.0, holdAngle = 0.0, flagPhase = 0.0, flagAngle = -0.5
    private var flowPhase = 0.0, sweepAngle = -Double.pi / 2
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

        // Breathing and level reactions are deliberately small; the inner clouds carry the motion.
        var goal = Frame()
        switch mode {
        case .idle:
            goal.scale = reduce ? 1 : 1 + 0.012 * sin(2 * .pi * t / 4.0)
            goal.flow = 0.8
        case .listening:
            goal.scale = reduce ? 1 + 0.04 * v : 1.02 + 0.07 * v
            goal.glow = 0.42; goal.bodyOpacity = 1
            goal.rings = reduce ? 0 : 0.08 + 0.3 * v
            goal.flow = 1
        case .holding:
            goal.scale = 1.0
            goal.glow = 0.3; goal.bodyOpacity = 1
            goal.hold = 1
            goal.flow = 0.8
        case .processing:
            goal.scale = reduce ? 1.01 : 1.01 + 0.01 * sin(2 * .pi * t / 1.4)
            goal.glow = 0.34; goal.bodyOpacity = 1
            goal.angular = 1; goal.dots = reduce ? 0 : 1
            goal.sweep = 1
            goal.flow = 0.75
        case .speaking(let lang):
            goal.scale = reduce ? 1 + 0.04 * v : 1.03 + 0.08 * v
            goal.glow = 0.42; goal.bodyOpacity = 1
            goal.rippleAlpha = 1
            goal.flag = lang == nil ? 0 : 1
            goal.flow = 1
            if let lang { cur.flagLang = lang }
        case .disabled:
            goal.scale = 0.96; goal.glow = 0; goal.bodyOpacity = 1; goal.grey = 1
        }

        let k = min(1, dt / 0.25)
        func ease(_ a: inout Double, _ b: Double) { a += (b - a) * k }
        ease(&cur.scale, goal.scale); ease(&cur.glow, goal.glow)
        ease(&cur.bodyOpacity, goal.bodyOpacity); ease(&cur.rings, goal.rings)
        ease(&cur.angular, goal.angular); ease(&cur.dots, goal.dots); ease(&cur.grey, goal.grey)
        ease(&cur.rippleAlpha, goal.rippleAlpha); ease(&cur.hold, goal.hold)
        ease(&cur.flag, goal.flag); ease(&cur.flow, goal.flow); ease(&cur.sweep, goal.sweep)
        settled = mode == .disabled && abs(cur.grey - 1) < 0.01 && abs(cur.scale - 0.96) < 0.002

        if !reduce {
            if mode == .processing { rotation += dt * 2 * .pi / 2.4; sweepAngle += dt * 2 * .pi / 1.4 }
            if mode == .holding { holdAngle += dt * 2 * .pi / 3.0 }
            // Cloud drift: calm when stopped, livelier while listening/speaking, quickest while connecting.
            // A steady pace per state — it never follows the mic. (×1.4 of the first cloud version, owner's ask.)
            let flowSpeed: Double = switch mode {
            case .idle: 0.77
            case .listening, .speaking: 1.26
            case .processing: 1.96
            case .holding: 0.7
            case .disabled: 0
            }
            flowPhase += dt * flowSpeed
            if case .some(.some(let l)) = speakingLang {
                if case .korea = l.flag { flagAngle += dt * 2 * .pi / 6.0 }      // turning taegeuk
                else { flagPhase += dt * 2 * .pi / 1.2; flagAngle += dt * 2 * .pi / 8.0 } // waving bands
            }
            if isSpeaking, v > 0.05, t - lastRipple > 0.6 { rippleStarts.append(t); lastRipple = t }
        }
        rippleStarts.removeAll { t - $0 > 1.4 }
        cur.rotation = rotation
        cur.holdAngle = holdAngle
        cur.flagPhase = flagPhase
        cur.flagAngle = flagAngle
        cur.flowPhase = flowPhase
        cur.sweepAngle = sweepAngle
        cur.ripples = rippleStarts.map { (t - $0) / 1.4 }
        return cur
    }
}

import SwiftUI

/// 중앙 오브. 피그마 "오브 모션 스펙"(node 9:37)과 같은 숫자를 쓴다.
/// - idle: 느린 호흡(마이크 꺼짐)
/// - listening: 실제 마이크 음량에 반응
/// - processing: 회전하는 각도 그라데이션 + 궤도 점(신호 없음)
/// - speaking: 실제 재생 음량에 반응 + 파문
/// - disabled: 정지 회색(중지·오류·권한 거부) — 듣는 것처럼 보이지 않게 움직이지 않는다
struct OrbView: View {
    enum Mode: Equatable { case idle, listening, processing, speaking, disabled }

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
                    draw(&gc, size: size, f: f, t: t)
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

    private func draw(_ gc: inout GraphicsContext, size: CGSize, f: OrbDriver.Frame, t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = 95 * f.scale
        let stops = scheme == .dark ? [0xFF6E33, 0xFF4A66, 0xFF4090] : [0xFF5A1E, 0xF8324E, 0xF0276A]
        let colors = stops.map { Color(UIColor(hex: UInt32($0))) }
        let linear = Gradient(stops: [.init(color: colors[0], location: 0), .init(color: colors[1], location: 0.62), .init(color: colors[2], location: 1)])
        let tl = CGPoint(x: c.x - R, y: c.y - R), br = CGPoint(x: c.x + R, y: c.y + R)
        let color = 1 - f.grey

        // 글로우
        if f.glow * color > 0.01 {
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 40))
                layer.opacity = f.glow * color
                let r = R * 1.02
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r + 12, width: r * 2, height: r * 2)), with: .linearGradient(linear, startPoint: tl, endPoint: br))
            }
        }
        // 호흡 범위 / 반응 고리
        for (k, op) in [(1.16, 0.22), (1.3, 0.1)] where f.rings > 0.01 {
            let r = R * k
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Theme.accent.opacity(op * f.rings * 2.2)), lineWidth: 2)
        }
        // 출력 파문
        for p in f.ripples {
            let r = R * (1 + 0.5 * p)
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Theme.accent.opacity(0.35 * (1 - p) * f.rippleAlpha)), lineWidth: 2)
        }
        // 몸체
        let body = blob(center: c, radius: R, amp: f.amp, phase: f.wobblePhase)
        if f.grey > 0.99 {
            gc.fill(body, with: .color(Theme.selected))
        } else {
            var g = gc
            g.opacity = f.bodyOpacity
            if f.angular > 0.01 {
                let ang = Gradient(colors: [colors[0], colors[1], colors[2], colors[0]])
                g.fill(body, with: .conicGradient(ang, center: c, angle: .radians(f.rotation)))
                if f.angular < 0.99 {
                    var g2 = g
                    g2.opacity = f.bodyOpacity * (1 - f.angular)
                    g2.fill(body, with: .linearGradient(linear, startPoint: tl, endPoint: br))
                }
            } else {
                g.fill(body, with: .linearGradient(linear, startPoint: tl, endPoint: br))
            }
            if f.grey > 0.01 {
                var g3 = gc
                g3.opacity = f.grey
                g3.fill(body, with: .color(Theme.selected))
            }
            // 하이라이트
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 26))
                layer.opacity = 0.35 * color
                let hr = R * 0.55
                layer.fill(Path(ellipseIn: CGRect(x: c.x - R * 0.75, y: c.y - R * 0.85, width: hr * 2, height: hr * 2)), with: .color(.white))
            }
        }
        // 궤도 점
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

/// 프레임마다 목표값으로 부드럽게 다가가며 오브 모양 값을 계산한다(상태 전환 250ms).
final class OrbDriver {
    struct Frame {
        var scale = 1.0, amp = 0.0, glow = 0.22, bodyOpacity = 0.92, rings = 0.0
        var angular = 0.0, dots = 0.0, grey = 0.0, rippleAlpha = 0.0
        var rotation = 0.0, wobblePhase = 0.0
        var ripples: [Double] = []
    }

    private var last: Double?
    private var cur = Frame()
    private var v: Double = 0          // 평활된 음량 0~1
    private var rotation = 0.0
    private var wobble = 0.0
    private var rippleStarts: [Double] = []
    private var lastRipple = 0.0
    private(set) var settled = false

    func step(t: Double, mode: OrbView.Mode, input: Float, output: Float, reduce: Bool) -> Frame {
        let dt = min(0.05, max(0, t - (last ?? t)))
        last = t

        // 음량 평활: 상승 60ms, 하강 250ms
        let raw: Double = mode == .listening ? Double(input) : mode == .speaking ? Double(output) : 0
        let target = min(1, max(0, raw * 9))
        let tau = target > v ? 0.06 : 0.25
        v += (target - v) * min(1, dt / tau)

        var goal = Frame()
        switch mode {
        case .idle:
            goal.scale = reduce ? 1 : 1.02 + 0.02 * sin(2 * .pi * t / 4.0)
            goal.glow = 0.22; goal.bodyOpacity = 0.92
        case .listening:
            goal.scale = reduce ? 1 + 0.06 * v : 1.08 + 0.18 * v
            goal.amp = reduce ? 0 : 0.02 + 0.08 * v
            goal.glow = 0.5; goal.bodyOpacity = 1
            goal.rings = reduce ? 0 : 0.1 + 0.3 * v
        case .processing:
            goal.scale = reduce ? 1.02 : 1.02 + 0.015 * sin(2 * .pi * t / 1.2)
            goal.amp = reduce ? 0 : 0.025
            goal.glow = 0.32; goal.bodyOpacity = 1
            goal.angular = 1; goal.dots = reduce ? 0 : 1
        case .speaking:
            goal.scale = reduce ? 1 + 0.06 * v : 1.05 + 0.15 * v
            goal.amp = reduce ? 0 : 0.015 + 0.06 * v
            goal.glow = 0.45; goal.bodyOpacity = 1
            goal.rippleAlpha = 1
        case .disabled:
            goal.scale = 0.96; goal.glow = 0; goal.bodyOpacity = 1; goal.grey = 1
        }

        let k = min(1, dt / 0.25)
        func ease(_ a: inout Double, _ b: Double) { a += (b - a) * k }
        ease(&cur.scale, goal.scale); ease(&cur.amp, goal.amp); ease(&cur.glow, goal.glow)
        ease(&cur.bodyOpacity, goal.bodyOpacity); ease(&cur.rings, goal.rings)
        ease(&cur.angular, goal.angular); ease(&cur.dots, goal.dots); ease(&cur.grey, goal.grey)
        // 재생이 끝나면 남은 파문도 같이 빠르게 사라지게(대기가 듣는 것처럼 보이지 않도록)
        ease(&cur.rippleAlpha, goal.rippleAlpha)
        settled = mode == .disabled && abs(cur.grey - 1) < 0.01 && abs(cur.scale - 0.96) < 0.002

        if !reduce {
            if mode == .processing { rotation += dt * 2 * .pi / 2.4 }
            if mode != .disabled { wobble += dt * 1.6 }
            // 출력 파문: 소리가 날 때 0.6초마다, 1.4초 동안 퍼지며 사라짐
            if mode == .speaking, v > 0.05, t - lastRipple > 0.6 { rippleStarts.append(t); lastRipple = t }
        }
        rippleStarts.removeAll { t - $0 > 1.4 }
        cur.rotation = rotation
        cur.wobblePhase = wobble
        cur.ripples = rippleStarts.map { (t - $0) / 1.4 }
        return cur
    }
}

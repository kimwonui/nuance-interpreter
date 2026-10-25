import SwiftUI

/// One half of the face-to-face screen. The top half (the other person) is shown rotated 180° so they can
/// read it from across the table. Turn cues are guidance only: NUA still interprets whoever speaks first.
struct SideHalf: View {
    enum Cue: Equatable { case idle, yourTurn, talking, waitOther, listen, muted }

    @ObservedObject var controller: InterpreterController
    let side: InterpreterController.Side
    let cue: Cue

    @State private var showPicker = false
    private var lang: Lang { side == .me ? controller.leftLang : controller.rightLang }
    private var otherLang: Lang { side == .me ? controller.rightLang : controller.leftLang }
    private var editable: Bool { controller.autoState == .off }

    var body: some View {
        ZStack {
            FlagBackground(lang: lang, cue: cue, flowFromTop: true)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
            VStack(spacing: 6) {
                languageChip
                Text(title).font(.noto(17, .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.noto(13, .regular)).foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(side == .me ? "Your side" : "Other person's side"), \(lang.name). \(title). \(subtitle)")
    }

    @ViewBuilder
    private var languageChip: some View {
        let label = HStack(spacing: 6) {
            Text(lang.name).font(.noto(15, .bold)).foregroundStyle(Theme.text)
            if !lang.tried {
                Text("Experimental").font(.noto(10, .bold)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.badge, in: Capsule())
            }
            if editable { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.surfaceRaised.opacity(0.9), in: Capsule())
        if editable {
            Button { showPicker = true } label: { label }
                .accessibilityLabel("\(side == .me ? "Your" : "Their") language: \(lang.name). Double-tap to search and change")
                .sheet(isPresented: $showPicker) {
                    LanguagePickerSheet(controller: controller, side: side)
                        .presentationDetents([.large])
                }
        } else {
            label
        }
    }

    private var oneWayListener: Bool { controller.isOneWay && side == .them }

    private var title: String {
        switch cue {
        case .idle: return side == .me ? "You speak \(lang.name)" : (oneWayListener ? "They hear \(lang.name)" : "They speak \(lang.name)")
        case .yourTurn: return "Your turn"
        case .talking: return "Speaking \(lang.name)…"
        case .waitOther: return "Wait for them to finish"
        case .listen: return "Listen"
        case .muted: return "Muted"
        }
    }

    private var subtitle: String {
        switch cue {
        case .idle:
            if controller.autoState == .off { return editable ? "Tap to change language" : "" }
            return oneWayListener ? "One-way: only \(otherLang.name) is interpreted" : "Speak when ready"
        case .yourTurn: return "Speak \(lang.name)"
        case .talking: return "NUA will interpret when you pause"
        case .waitOther: return "They are speaking \(otherLang.name)"
        case .listen: return "Translation in \(lang.name)"
        case .muted: return "Mic off"
        }
    }
}

/// Soft flag background for a half. Steady opacity per state, changing smoothly only when the state changes:
/// talking = clearly visible and still (no pulsing with the mic), listening = the flag waves and a light band
/// flows toward the listener while NUA plays the translation, your turn = gentle breathing.
struct FlagBackground: View {
    let lang: Lang
    let cue: SideHalf.Cue
    /// true for the bottom half: the flow comes from the top edge (the orb side).
    let flowFromTop: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.surface
            TimelineView(.animation(paused: reduceMotion || !(cue == .yourTurn || cue == .listen))) { tl in
                Canvas { gc, size in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    var layer = gc
                    if cue == .yourTurn && !reduceMotion { layer.opacity = 0.75 + 0.25 * sin(2 * .pi * t / 3.0) } // gentle breathing
                    let moving = cue == .listen && !reduceMotion
                    FlagPainter.paint(lang.flag, in: &layer, rect: CGRect(origin: .zero, size: size),
                                      phase: moving ? t * 1.2 : 0, angle: moving ? t * 0.4 : 0, wave: moving ? 3 : 0)
                }
            }
            .opacity(baseOpacity)
            .animation(.easeInOut(duration: 0.35), value: cue)
            if cue == .listen && !reduceMotion {
                TimelineView(.animation) { tl in
                    Canvas { gc, size in
                        // Light flowing from the orb toward this person: "this is for you to hear".
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let p = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
                        let y = flowFromTop ? size.height * p : size.height * (1 - p)
                        let band = CGRect(x: 0, y: y - size.height * 0.18, width: size.width, height: size.height * 0.36)
                        gc.fill(Path(band), with: .linearGradient(
                            Gradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)]),
                            startPoint: CGPoint(x: 0, y: band.minY), endPoint: CGPoint(x: 0, y: band.maxY)))
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var baseOpacity: Double {
        switch cue {
        case .idle, .muted: return 0.06
        case .waitOther: return 0.04
        case .yourTurn: return 0.18
        case .talking: return 0.34 // clearly visible, steady
        case .listen: return 0.22
        }
    }
}

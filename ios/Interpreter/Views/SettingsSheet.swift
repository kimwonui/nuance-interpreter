import SwiftUI

/// I06 설정.
struct SettingsSheet: View {
    @ObservedObject var controller: InterpreterController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("uiVersion") private var uiVersion = "orb"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Settings").font(.noto(20, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surface, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }

                group("Languages", note: "The engine supports more languages. More will be added over time.") {
                    row("globe", "My language", controller.leftLang.name)
                    row("globe", "Other language", controller.rightLang.name)
                }

                group("Screen", note: "Cards is the previous design, kept for comparison.") {
                    Picker("Screen", selection: $uiVersion) {
                        Text("Orb").tag("orb")
                        Text("Cards (previous)").tag("card")
                    }
                    .pickerStyle(.segmented)
                    .padding(12)
                }

                group("Speaker switching", note: "Each speaker taps their own language button. Automatic detection isn't available yet.") {
                    row("hand.tap", "Mode", "Buttons")
                }

                group("Audio", note: "Audio switches automatically when you connect headphones or Bluetooth.") {
                    row("headphones", "Output now", controller.route)
                }

                group("Measurement", note: nil) {
                    Toggle(isOn: $controller.showLatency) {
                        Label("Show latency", systemImage: "timer").font(.noto(15, .medium)).foregroundStyle(Theme.text)
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if !controller.latency.isEmpty { latencySummary }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.accentText)
                    Text("Audio and conversations are never saved on this device. Audio is streamed to OpenAI in real time for interpretation, and on-screen history is cleared when you close the app.")
                        .font(.noto(13, .regular))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Theme.badge, in: RoundedRectangle(cornerRadius: Radius.lg))

                Button(role: .destructive) { controller.clearHistory(); dismiss() } label: {
                    Text("Clear history").font(.noto(15, .bold)).frame(maxWidth: .infinity).frame(height: 48)
                }
                .disabled(controller.turns.isEmpty || controller.phase != .idle)

                Text("Server: \(controller.serverDescription)").font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
            }
            .padding(20)
        }
        .background(Theme.background)
    }

    private var latencySummary: some View {
        let vals = controller.latency.compactMap(\.endToFirstSound).sorted()
        let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(vals.count) samples · avg \(String(format: "%.2f", avg))s · slowest \(String(format: "%.2f", vals.last ?? 0))s")
                .font(.noto(13, .medium)).foregroundStyle(Theme.text)
            Text("Measured from tapping Done to translated audio starting (this session only)")
                .font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func group<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.noto(13, .medium)).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) { content() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
            if let note {
                Text(note).font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Theme.textSecondary)
            Text(title).font(.noto(15, .medium)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.noto(15, .medium)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

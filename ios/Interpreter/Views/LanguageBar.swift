import SwiftUI

struct LanguageBar: View {
    @ObservedObject var controller: InterpreterController

    var body: some View {
        HStack(spacing: 4) {
            chip(controller.leftLang, left: true)
            Button { controller.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 36)
            }
            .accessibilityLabel("Swap languages")
            chip(controller.rightLang, left: false)
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
        .background(Theme.surface, in: Capsule())
        .disabled(controller.phase != .idle)
    }

    private func chip(_ lang: Lang, left: Bool) -> some View {
        Menu {
            ForEach(Lang.allCases.filter { !$0.liveOnly }) { l in
                Button(l.name) { controller.setLanguage(l, left: left) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(lang.code).font(.noto(11, .bold)).foregroundStyle(Theme.accentText)
                Text(lang.name).font(.noto(15, .bold)).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Theme.surfaceRaised, in: Capsule())
        }
    }
}

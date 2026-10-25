import SwiftUI

/// Searchable language picker for one person (search by English name, native name, or code).
/// Lists only the languages the deployed server accepts; the choice becomes the session's language pair.
struct LanguagePickerSheet: View {
    @ObservedObject var controller: InterpreterController
    let side: InterpreterController.Side
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var current: Lang { side == .me ? controller.leftLang : controller.rightLang }
    private var other: Lang { side == .me ? controller.rightLang : controller.leftLang }
    private var results: [Lang] { controller.availableLangs.filter { $0.matches(query) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results) { lang in
                        Button {
                            controller.setLanguage(lang, for: side)
                            dismiss()
                        } label: { row(lang) }
                        .accessibilityLabel("\(lang.name), \(lang.nativeName)\(lang.tried ? "" : ", experimental")\(lang.liveOnly ? ", GPT-Live only" : "")\(lang == current ? ", selected" : "")")
                    }
                } footer: {
                    Text(footnote).font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
                }
            }
            .overlay {
                if results.isEmpty {
                    Text("No matching language").font(.noto(14, .regular)).foregroundStyle(Theme.textSecondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name, native name, or code")
            .task { await controller.loadLanguages() } // picks up new languages as soon as the server offers them
            .navigationTitle(side == .me ? "Your language" : "Their language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func row(_ lang: Lang) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(lang.name).font(.noto(16, .bold)).foregroundStyle(Theme.text)
                    Text(lang.code).font(.noto(11, .bold)).foregroundStyle(Theme.textSecondary)
                }
                Text(lang.liveOnly ? "\(lang.nativeName) · GPT-Live only" : lang.nativeName).font(.noto(13, .regular)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if lang == other {
                Text(side == .me ? "Their language" : "Your language").font(.noto(10, .medium)).foregroundStyle(Theme.textSecondary)
            }
            Text(lang.tried ? "Tried" : "Experimental")
                .font(.noto(10, .bold))
                .foregroundStyle(lang.tried ? Theme.textSecondary : Theme.accentText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(lang.tried ? AnyShapeStyle(Theme.selected) : AnyShapeStyle(Theme.badge), in: Capsule())
            if lang == current {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private var footnote: String {
        var text = "OpenAI does not publish a language list for GPT-Live. Only Korean and English have been tried; the others are experimental and not tested. Arabic and Gujarati work only with GPT-Live: the backup interpreter model can hear them but can't speak them. Picking the other person's language swaps the two."
        if controller.availableLangs.count <= 2 {
            text += " More languages appear after the NUA server update is installed."
        }
        return text
    }
}

import AppKit
import SwiftUI

/// Paste a subscription link or keys. Menu bar apps have no Edit menu, so
/// ⌘V may not reach the text field: the "Вставить из буфера" button covers that.
struct AddKeysView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(spacing: 8) {
            ScreenHeader("Добавить")

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ссылка на подписку или ключи")
                        .font(.system(size: 13, weight: .semibold))
                    Text("https://… от продавца VPN, ключи vless:// и hysteria2:// или JSON — по одному в строке.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $text)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 110)
                        .background(Palette.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Ключи или ссылка на подписку")

                    HStack {
                        Button {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                text = pasted
                            }
                        } label: {
                            Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Button {
                            Task {
                                await model.importText(text)
                                if model.lastImport?.succeeded == true { text = "" }
                            }
                        } label: {
                            if model.isImporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Добавить")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isImporting)
                    }
                }
            }

            if let summary = model.lastImport {
                ImportSummaryCard(summary: summary)
            }

            Label("Ключи хранятся только в Связке ключей этого Mac", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
        }
        .onDisappear { model.clearImportSummary() }
    }
}

private struct ImportSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: AppModel.ImportSummary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if summary.succeeded {
                    Label(resultText, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tint)
                }
                ForEach(summary.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                }
                ForEach(summary.problems.prefix(5), id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(summary.succeeded ? Palette.ink2 : Palette.warn)
                }
                if summary.succeeded {
                    Button("К серверам") { model.route = .servers }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var resultText: String {
        var parts: [String] = []
        if summary.subscriptions > 0 {
            parts.append(Format.plural(summary.subscriptions, "подписка", "подписки", "подписок"))
        }
        parts.append(Format.plural(summary.servers, "сервер", "сервера", "серверов"))
        return "Добавлено: " + parts.joined(separator: ", ")
    }
}

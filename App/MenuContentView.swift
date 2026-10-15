import AppKit
import SwiftUI

/// The window that opens from the menu bar icon (see docs/DESIGN.md).
/// For now it is a skeleton: connecting and servers arrive in later stages.
struct MenuContentView: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable

    var body: some View {
        VStack(spacing: density.gap) {
            header
            StatusCard()
            ServersCard()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield")
                .font(.system(size: 14, weight: .medium))
            Text("VPNforYou")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("Настройки")
            .accessibilityLabel("Настройки")
        }
        .padding(.leading, 6)
    }

    private var footer: some View {
        HStack {
            Text("Версия \(Bundle.main.appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink3)
            Spacer()
            Button("Выйти") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

private struct StatusCard: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Palette.track)
                            .frame(width: 8, height: 8)
                        Text("Не подключено")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text("Подключение появится в следующих версиях")
                        .foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 12)
                Toggle("VPN", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
                    .disabled(true)
            }
        }
    }
}

private struct ServersCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("СЕРВЕРЫ")
                Text("Пока пусто")
                    .font(.system(size: 13, weight: .medium))
                Text("Импорт ключей и подписок появится в следующей версии.")
                    .foregroundStyle(Palette.ink2)
            }
        }
    }
}

/// White card with a hairline border, padding follows the density setting.
struct Card<Content: View>: View {
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(density.padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.line)
            )
    }
}

struct SectionLabel: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink3)
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

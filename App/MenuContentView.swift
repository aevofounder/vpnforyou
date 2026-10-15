import AppKit
import SwiftUI

/// The window that opens from the menu bar icon (see docs/DESIGN.md).
/// Simple in-window navigation: home, servers, add keys.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable

    var body: some View {
        VStack(spacing: density.gap) {
            switch model.route {
            case .home:
                header
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                StatusCard()
                CurrentServerCard()
                footer
            case .servers:
                ServersView()
            case .add:
                AddKeysView()
            }
        }
        .padding(12)
        .frame(width: 360)
        .background { WindowBackground() }
        .foregroundStyle(Palette.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusPill(text: "VPN выключен", isOn: false)
            Spacer()
            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .foregroundStyle(Palette.ink2)
            .help("Настройки")
            .accessibilityLabel("Настройки")
        }
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
                        Text("Выключено")
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

/// The selected server, or an invitation to add keys.
private struct CurrentServerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            if let current = model.currentSelection {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        model.route = .servers
                    } label: {
                        HStack(spacing: 10) {
                            if current.isGroup {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 20)
                                    .background(.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            } else {
                                CountryChip(code: current.code)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(current.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(current.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.ink3)
                        }
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Открыть список серверов")

                    if let usage = current.usage {
                        Divider()
                        UsageView(usage: usage)
                    }
                }
            } else if model.hasServers {
                Button {
                    model.route = .servers
                } label: {
                    HStack {
                        Text("Выберите сервер")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Palette.ink3)
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("СЕРВЕРЫ")
                    Text("Пока пусто")
                        .font(.system(size: 13, weight: .medium))
                    Text("Вставьте ссылку на подписку от продавца VPN или ключи vless:// и hysteria2://.")
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Добавить ключ или подписку") { model.route = .add }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Status pill in the header, in the spirit of the Dynamic Island:
/// "VPN выключен" now, later "NL · 00:12:41" while connected.
struct StatusPill: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let text: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOn ? accent.color : Palette.track)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassCapsule(tint: isOn ? accent.color.opacity(0.25) : nil)
        .accessibilityElement(children: .combine)
    }
}

/// Content card. On glass it is a light translucent fill (no glass on glass),
/// on the solid material a white card. Padding follows the density setting.
struct Card<Content: View>: View {
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable
    @AppStorage(AppearanceKey.material) private var material: WindowMaterial = .glass
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(density.padding)
            .background(material == .solid ? Palette.surface : Palette.glassFill, in: shape)
            .overlay(shape.strokeBorder(material == .solid ? Palette.line : Palette.glassEdge))
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

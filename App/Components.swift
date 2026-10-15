import SwiftUI
import VPNCore

/// Header of a sub-screen in the menu bar window: "Назад", title, optional action.
struct ScreenHeader<Trailing: View>: View {
    @Environment(AppModel.self) private var model
    private let title: String
    private let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            HStack {
                Button {
                    model.route = .home
                } label: {
                    Label("Назад", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 4)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink2)
                .keyboardShortcut(.cancelAction)
                Spacer()
                trailing
            }
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

struct CountryChip: View {
    let code: String?

    var body: some View {
        Text(code ?? "—")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.ink2)
            .frame(minWidth: 28, minHeight: 20)
            .padding(.horizontal, 3)
            .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(code.map { "Страна \($0)" } ?? "Страна неизвестна")
    }
}

/// One server or auto-select group: its own tile, so rows are clearly apart.
struct ServerRowButton: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    private let code: String?
    private let title: String
    private let subtitle: String
    private let isGroup: Bool
    private let isSelected: Bool
    private let ping: Int?
    private let pingFailed: Bool
    private let action: () -> Void

    init(code: String?, title: String, subtitle: String, isGroup: Bool, isSelected: Bool,
         ping: Int? = nil, pingFailed: Bool = false, action: @escaping () -> Void) {
        self.code = code
        self.title = title
        self.subtitle = subtitle
        self.isGroup = isGroup
        self.isSelected = isSelected
        self.ping = ping
        self.pingFailed = pingFailed
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                if isGroup {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 20)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    CountryChip(code: code)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                PingBadge(milliseconds: ping, failed: pingFailed)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(isSelected ? accent.color.opacity(0.14) : Palette.glassFill, in: shape)
            .overlay(shape.strokeBorder(isSelected ? accent.color.opacity(0.5) : Palette.line))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Traffic used and days left of a subscription.
struct UsageView: View {
    let usage: SubscriptionUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = usage.fractionUsed {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule()
                            .fill(.tint)
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            Text(Format.usage(usage))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.ink2)
        }
    }
}

/// Dark capsule at the bottom with an action, e.g. "Подписка удалена · Вернуть".
struct UndoToast: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(Color.black.opacity(0.82), in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

import AppKit
import SwiftUI

/// UserDefaults keys for the appearance settings.
enum AppearanceKey {
    static let theme = "appearance.theme"
    static let accent = "appearance.accent"
    static let density = "appearance.density"
    static let material = "appearance.material"
    static let hideIP = "privacy.hideIP"
    static let menuIcon = "appearance.menuIcon"
    static let cards = "appearance.cards"
}

/// What the menu bar shows: the shield, a dot, the country code or the speed.
enum MenuIconStyle: String, CaseIterable, Identifiable {
    case shield, dot, country, speed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shield: "Щит"
        case .dot: "Точка"
        case .country: "Код страны"
        case .speed: "Скорость"
        }
    }
}

/// Cards of the home screen below the status card, in the user's order.
enum HomeCard: String, CaseIterable, Identifiable {
    case ip, server, tiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ip: "IP-адрес"
        case .server: "Текущий сервер"
        case .tiles: "Плитки: скорость, программы, активность"
        }
    }
}

/// Stored as "ip,server,-tiles": order, and a minus for hidden cards.
struct CardLayout: Equatable {
    var items: [(card: HomeCard, visible: Bool)]

    init(_ raw: String) {
        var items: [(card: HomeCard, visible: Bool)] = []
        for part in raw.split(separator: ",") {
            let hidden = part.hasPrefix("-")
            guard let card = HomeCard(rawValue: String(hidden ? part.dropFirst() : part)),
                  !items.contains(where: { $0.card == card }) else { continue }
            items.append((card: card, visible: !hidden))
        }
        for card in HomeCard.allCases where !items.contains(where: { $0.card == card }) {
            items.append((card: card, visible: true))
        }
        self.items = items
    }

    var raw: String {
        items.map { ($0.visible ? "" : "-") + $0.card.rawValue }.joined(separator: ",")
    }

    var visibleCards: [HomeCard] {
        items.filter(\.visible).map(\.card)
    }

    static func == (lhs: CardLayout, rhs: CardLayout) -> Bool { lhs.raw == rhs.raw }

    mutating func move(_ card: HomeCard, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.card == card }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    mutating func setVisible(_ card: HomeCard, _ visible: Bool) {
        guard let index = items.firstIndex(where: { $0.card == card }) else { return }
        items[index].visible = visible
    }
}

/// Window material. Liquid Glass needs macOS 26; on macOS 14–15
/// the app falls back to the system's frosted material.
enum WindowMaterial: String, CaseIterable, Identifiable {
    case glass, frosted, solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "Матовое стекло"
        case .solid: "Сплошной"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Accent options from docs/DESIGN.md. All of them keep white text readable.
enum AccentColor: String, CaseIterable, Identifiable {
    case blue, green, orange, violet, graphite, raspberry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "Синий"
        case .green: "Зелёный"
        case .orange: "Оранжевый"
        case .violet: "Фиолетовый"
        case .graphite: "Графит"
        case .raspberry: "Малиновый"
        }
    }

    var color: Color {
        switch self {
        case .blue: Color(hex: 0x2F5BD3)
        case .green: Color(hex: 0x1D7A50)
        case .orange: Color(hex: 0xB8541A)
        case .violet: Color(hex: 0x6246C9)
        case .graphite: Color(hex: 0x3B3E44)
        case .raspberry: Color(hex: 0xB4366E)
        }
    }
}

enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: "Просторно"
        case .compact: "Компактно"
        }
    }

    /// Padding inside a card.
    var padding: CGFloat { self == .comfortable ? 14 : 10 }

    /// Gap between cards.
    var gap: CGFloat { self == .comfortable ? 10 : 6 }
}

/// Color tokens from docs/DESIGN.md: light and dark values.
enum Palette {
    static let background = Color.adaptive(light: 0xF4F4F1, dark: 0x121315)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1B1C1F)
    static let surface2 = Color.adaptive(light: 0xEEEEEA, dark: 0x25262A)
    static let ink = Color.adaptive(light: 0x17181A, dark: 0xEDEDEA)
    static let ink2 = Color.adaptive(light: 0x4F525A, dark: 0xB0B3B9)
    static let ink3 = Color.adaptive(light: 0x686B72, dark: 0x8E9198)
    static let line = Color.adaptive(light: 0xE2E2DD, dark: 0x2C2D31)
    static let track = Color.adaptive(light: 0xCBCBC6, dark: 0x45464C)
    static let warn = Color.adaptive(light: 0x9A5B00, dark: 0xE0A33A)
    static let bad = Color.adaptive(light: 0xB3261E, dark: 0xF2766B)

    /// Translucent card fill and edge used on top of glass.
    static let glassFill = Color.adaptive(light: 0xFFFFFF, lightAlpha: 0.5, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let glassEdge = Color.adaptive(light: 0xFFFFFF, lightAlpha: 0.6, dark: 0xFFFFFF, darkAlpha: 0.08)
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// A color that follows the light/dark appearance of the window it is drawn in.
    static func adaptive(
        light: UInt32, lightAlpha: CGFloat = 1,
        dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

import SwiftUI

// Liquid Glass (macOS 26) with fallbacks for macOS 14–15.
// The window itself uses the system material; glass goes on small
// floating controls (status pill, icon buttons), not on content cards.

/// Background of the menu bar window for the chosen material.
struct WindowBackground: View {
    @AppStorage(AppearanceKey.material) private var material: WindowMaterial = .glass

    var body: some View {
        switch material {
        case .solid:
            Palette.background
        case .frosted:
            Rectangle().fill(.regularMaterial)
        case .glass:
            // On macOS 26 the menu bar window is already Liquid Glass;
            // on earlier versions use the thinnest system material.
            if #available(macOS 26.0, *) {
                Color.clear
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

/// Capsule background for small floating elements such as the status pill.
struct GlassCapsule: ViewModifier {
    @AppStorage(AppearanceKey.material) private var material: WindowMaterial = .glass
    private let tint: Color?

    init(tint: Color?) {
        self.tint = tint
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if material == .solid {
            content
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(tint == nil ? .regular : .regular.tint(tint!), in: Capsule())
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.glassEdge))
        }
    }
}

extension View {
    func glassCapsule(tint: Color? = nil) -> some View {
        modifier(GlassCapsule(tint: tint))
    }

    /// `.glass` button style on macOS 26, plain borderless button before that.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.plain)
        }
    }
}

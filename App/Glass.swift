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

    /// Neutral round (or capsule) button: Liquid Glass on macOS 26, the thin
    /// system material before that, a light solid chip for the solid material.
    /// The accent color stays for state (the switch, the selected server),
    /// not for every toolbar button.
    func glassButtonStyle(capsule: Bool = false) -> some View {
        buttonStyle(.plain).modifier(GlassButtonBackground(capsule: capsule))
    }
}

struct GlassButtonBackground: ViewModifier {
    @AppStorage(AppearanceKey.material) private var material: WindowMaterial = .glass
    let capsule: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let label = content
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, capsule ? 12 : 0)
            .frame(minHeight: capsule ? 28 : nil)
        let shape = capsule ? AnyShape(Capsule()) : AnyShape(Circle())
        if material == .solid {
            label
                .background(Palette.surface, in: shape)
                .overlay(shape.stroke(Palette.line))
        } else if #available(macOS 26.0, *) {
            label.glassEffect(.regular, in: shape)
        } else {
            label
                .background(.thinMaterial, in: shape)
                .overlay(shape.stroke(Palette.glassEdge))
        }
    }
}

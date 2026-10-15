import SwiftUI
import VPNCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
        }
        .frame(width: 520)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable
    @AppStorage(AppearanceKey.hideIP) private var hideIP = false

    var body: some View {
        Form {
            Picker("Тема", selection: $theme) {
                ForEach(AppTheme.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Акцентный цвет") {
                HStack(spacing: 10) {
                    ForEach(AccentColor.allCases) { option in
                        AccentSwatch(option: option, isSelected: option == accent) {
                            accent = option
                        }
                    }
                }
            }

            Picker("Плотность", selection: $density) {
                ForEach(Density.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $hideIP) {
                Text("Скрывать IP-адреса")
                Text("Показывать \(IPMasker.mask("203.0.113.57")) — удобно при демонстрации экрана")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccentSwatch: View {
    let option: AccentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(option.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

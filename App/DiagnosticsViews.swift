import SwiftUI
import VPNCore

// MARK: - IP card

/// "Без VPN 203.0.•••.••• → Через VPN 198.51.•••.•••" with "IP сменился".
struct IPCard: View {
    @Environment(Diagnostics.self) private var diagnostics
    @Environment(ConnectionManager.self) private var connection
    @AppStorage(AppearanceKey.hideIP) private var hideIP = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel("IP-АДРЕС")
                    Spacer()
                    if let changed = diagnostics.ipChanged {
                        ChangeBadge(changed: changed)
                    }
                    refreshButton
                }
                if diagnostics.directIP == .idle, diagnostics.vpnIP == .idle {
                    Button("Проверить IP") { diagnostics.checkIP(connection: connection) }
                        .buttonStyle(.bordered)
                } else {
                    IPRow(title: "Без VPN", lookup: diagnostics.directIP, hideIP: hideIP)
                    if connection.state.isConnected {
                        IPRow(title: "Через VPN", lookup: diagnostics.vpnIP, hideIP: hideIP)
                    } else {
                        Text("Подключите VPN, чтобы сравнить")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if diagnostics.directIP == .loading || diagnostics.vpnIP == .loading {
            ProgressView().controlSize(.small).frame(width: 24, height: 24)
        } else {
            Button {
                diagnostics.checkIP(connection: connection)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("Проверить IP ещё раз")
            .accessibilityLabel("Проверить IP ещё раз")
        }
    }
}

private struct IPRow: View {
    let title: String
    let lookup: Diagnostics.Lookup
    let hideIP: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .frame(width: 72, alignment: .leading)
            switch lookup {
            case .idle:
                Text("—").foregroundStyle(Palette.ink3)
            case .loading:
                Text("проверяю…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink3)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(2)
            case .done(let info):
                CountryChip(code: info.countryCode)
                VStack(alignment: .leading, spacing: 0) {
                    Text(hideIP ? IPMasker.mask(info.ip) : info.ip)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let place = [info.city, info.organization].compactMap({ $0 }).first {
                        Text(place)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }
}

private struct ChangeBadge: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let changed: Bool

    var body: some View {
        Label(changed ? "IP сменился" : "IP не сменился",
              systemImage: changed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(changed ? accent.color : Palette.warn)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background((changed ? accent.color : Palette.warn).opacity(0.12), in: Capsule())
    }
}

// MARK: - Live traffic

/// "↓ 2,4 МБ/с  ↑ 120 КБ/с" and a sparkline of the last minute.
struct TrafficStrip: View {
    @Environment(ConnectionManager.self) private var connection
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue

    var body: some View {
        let samples = connection.traffic
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label(Format.rate(samples.last?.down ?? 0), systemImage: "arrow.down")
                Label(Format.rate(samples.last?.up ?? 0), systemImage: "arrow.up")
                    .foregroundStyle(Palette.ink2)
                Spacer()
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .labelStyle(TightLabelStyle())

            Sparkline(down: samples.map(\.down), up: samples.map(\.up), accent: accent.color)
                .frame(height: 34)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Скорость: загрузка \(Format.rate(samples.last?.down ?? 0)), отдача \(Format.rate(samples.last?.up ?? 0))")
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}

/// Two lines over the last 60 seconds: download filled with the accent, upload thin.
struct Sparkline: View {
    let down: [Int64]
    let up: [Int64]
    let accent: Color
    private let slots = 60

    var body: some View {
        Canvas { context, size in
            let peak = max(1, (down + up).max() ?? 1)
            func points(_ values: [Int64]) -> [CGPoint] {
                let step = size.width / CGFloat(slots - 1)
                let offset = slots - values.count
                return values.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index + offset) * step,
                            y: size.height - CGFloat(value) / CGFloat(peak) * (size.height - 2) - 1)
                }
            }
            let downPoints = points(down)
            if downPoints.count > 1 {
                var line = Path()
                line.addLines(downPoints)
                var area = line
                area.addLine(to: CGPoint(x: downPoints.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: downPoints.first!.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [accent.opacity(0.28), accent.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            let upPoints = points(up)
            if upPoints.count > 1 {
                var line = Path()
                line.addLines(upPoints)
                context.stroke(line, with: .color(Palette.ink3.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [3, 2]))
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(Palette.line), lineWidth: 1)
        }
    }
}

// MARK: - Ping badge

struct PingBadge: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let milliseconds: Int?
    let failed: Bool

    var body: some View {
        if let milliseconds {
            HStack(spacing: 4) {
                Circle().fill(color(for: milliseconds)).frame(width: 6, height: 6)
                Text("\(milliseconds) мс")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.ink2)
            }
            .accessibilityLabel("Пинг \(milliseconds) миллисекунд")
        } else if failed {
            Text("—")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink3)
                .help("Не удалось измерить. Hysteria2 работает по UDP: его пинг виден после подключения.")
                .accessibilityLabel("Пинг не измерен")
        }
    }

    private func color(for milliseconds: Int) -> Color {
        switch PingQuality(milliseconds: milliseconds) {
        case .good: accent.color
        case .fair: Palette.warn
        case .poor: Palette.bad
        }
    }
}

// MARK: - Speed test screen

struct SpeedTestView: View {
    @Environment(AppModel.self) private var model
    @Environment(Diagnostics.self) private var diagnostics
    @Environment(ConnectionManager.self) private var connection
    @State private var route: SpeedRoute = .vpn

    var body: some View {
        VStack(spacing: 8) {
            ScreenHeader("Скорость")

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Маршрут", selection: $route) {
                        ForEach(SpeedRoute.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(run?.isRunning == true)

                    bigNumber

                    HStack(spacing: 0) {
                        Metric(title: "Пинг", value: run?.latencyMs.map(Format.milliseconds), unit: nil,
                               active: run?.phase == .latency)
                        Metric(title: "Загрузка", value: run?.downloadMbps.map(Format.mbps), unit: "Мбит/с",
                               active: run?.phase == .download)
                        Metric(title: "Отдача", value: run?.uploadMbps.map(Format.mbps), unit: "Мбит/с",
                               active: run?.phase == .upload)
                    }

                    if case .failed(let message)? = run?.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warn)
                    }

                    HStack {
                        Text(footnote)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if run?.isRunning == true {
                            Button("Остановить") { diagnostics.cancelSpeedTest() }
                                .buttonStyle(.bordered)
                        } else {
                            Button(run == nil ? "Начать" : "Ещё раз") {
                                diagnostics.startSpeedTest(route: route, connection: connection,
                                                           serverName: connectedName)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(route == .vpn && !connection.state.isConnected)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }

            if !diagnostics.speedHistory.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("ИСТОРИЯ")
                        ForEach(diagnostics.speedHistory) { result in
                            HistoryRow(result: result)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !connection.state.isConnected { route = .direct }
        }
    }

    private var run: Diagnostics.SpeedRun? { diagnostics.speedRun }

    private var connectedName: String? {
        connection.connectedID.flatMap { model.label(for: $0)?.name }
    }

    private var footnote: String {
        if route == .vpn, !connection.state.isConnected { return "Для теста через VPN сначала подключитесь." }
        if let used = run?.bytesUsed, used > 0, run?.isRunning == false {
            return "Израсходовано \(Format.bytes(used)). speed.cloudflare.com"
        }
        return "speed.cloudflare.com · до \(Format.bytes(SpeedTest.maxTrafficBytes)) трафика"
    }

    @ViewBuilder
    private var bigNumber: some View {
        let value: Double? = run?.liveMbps ?? (run?.phase == .done ? run?.downloadMbps : nil)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map(Format.mbps) ?? "—")
                    .font(.system(size: 40, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: value)
                Text("Мбит/с")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink2)
            }
            Text(phaseText)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var phaseText: String {
        switch run?.phase {
        case .latency: "Измеряю пинг…"
        case .download: "Загрузка…"
        case .upload: "Отдача…"
        case .done: "Загрузка, \(run?.route.title.lowercased() ?? "")"
        case .failed: "Тест не прошёл"
        case nil: route == .vpn ? "Через выбранный сервер VPN" : "Без VPN, напрямую"
        }
    }
}

private struct Metric: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let title: String
    let value: String?
    let unit: String?
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                if active { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11))
            .foregroundStyle(active ? accent.color : Palette.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                if let unit, value != nil {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryRow: View {
    let result: SpeedResult

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.serverName.map { "\(result.route.title) · \($0)" } ?? result.route.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(Format.time(result.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 6)
            Text(summary)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.ink2)
        }
        .frame(minHeight: 30)
    }

    private var summary: String {
        let down = result.downloadMbps.map { "↓ " + Format.mbps($0) } ?? "↓ —"
        let up = result.uploadMbps.map { "↑ " + Format.mbps($0) } ?? "↑ —"
        let ping = result.latencyMs.map(Format.milliseconds) ?? "—"
        return "\(down)  \(up)  \(ping)"
    }
}

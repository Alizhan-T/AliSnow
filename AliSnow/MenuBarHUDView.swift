import SwiftUI

struct MenuBarHUDView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayManager: SnowOverlayManager
    @Environment(\.openWindow) private var openWindow

    @State private var hoveredMode: WeatherMode?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ZStack(alignment: .top) {
            // Subtle dynamic atmospheric top glow inspired by Alcove
            RadialGradient(
                colors: [
                    settings.weatherMode.accentColor.opacity(settings.isActive ? 0.28 : 0.08),
                    settings.weatherMode.secondaryColor.opacity(settings.isActive ? 0.10 : 0.02),
                    Color.clear
                ],
                center: .top,
                startRadius: 10,
                endRadius: 230
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: settings.weatherMode)
            .animation(.easeInOut(duration: 0.25), value: settings.isActive)

            VStack(spacing: 12) {
                headerBar
                weatherGrid
                controlsCard
                quickActionsRow
                footerBar
            }
            .padding(14)
        }
        .frame(width: 318)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                settings.weatherMode.accentColor.opacity(0.95),
                                settings.weatherMode.secondaryColor.opacity(0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .shadow(color: settings.weatherMode.accentColor.opacity(0.45), radius: 8, y: 2)

                Image(systemName: settings.weatherMode.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: settings.weatherMode)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("AliSnow")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(settings.isActive ? settings.weatherMode.subtitle : "Paused · 0% GPU")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    settings.isActive.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(settings.isActive ? settings.weatherMode.accentColor : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(settings.isActive ? "On" : "Off")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(settings.isActive ? settings.weatherMode.accentColor.opacity(0.22) : Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    settings.isActive ? settings.weatherMode.accentColor.opacity(0.55) : Color.white.opacity(0.14),
                                    lineWidth: 0.8
                                )
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var weatherGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATMOSPHERE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(WeatherMode.allCases) { mode in
                    weatherCard(for: mode)
                }
            }
        }
    }

    private func weatherCard(for mode: WeatherMode) -> some View {
        let isSelected = settings.weatherMode == mode
        let isHovered = hoveredMode == mode

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                settings.selectMode(mode)
                if !settings.isActive {
                    settings.isActive = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? [mode.accentColor.opacity(0.95), mode.secondaryColor.opacity(0.85)]
                                    : [mode.accentColor.opacity(0.20), mode.secondaryColor.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)

                    Image(systemName: mode.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : mode.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    Text(mode.supportsAccumulation ? "With drifts" : "Ambient")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.72) : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? mode.accentColor.opacity(0.20)
                            : Color.white.opacity(isHovered ? 0.10 : 0.055)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? mode.accentColor.opacity(0.65)
                                    : Color.white.opacity(isHovered ? 0.18 : 0.09),
                                lineWidth: isSelected ? 1.1 : 0.7
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredMode = hovering ? mode : (hoveredMode == mode ? nil : hoveredMode)
            }
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Intensity", systemImage: "dial.medium")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.intensity * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $settings.intensity, in: 0.1...1.0)
                    .tint(settings.weatherMode.accentColor)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Wind", systemImage: "wind")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(windDescription)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(value: $settings.windStrength, in: -2.0...2.0)
                    .tint(settings.weatherMode.accentColor)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7)
                )
        )
    }

    private var windDescription: String {
        let w = settings.windStrength
        if abs(w) < 0.08 { return "Calm" }
        let arrow = w > 0 ? "→" : "←"
        return "\(arrow) \(String(format: "%.1f", abs(w)))"
    }

    private var quickActionsRow: some View {
        HStack(spacing: 7) {
            quickPillToggle(
                title: (settings.weatherMode == .rain || settings.weatherMode == .storm) ? "Umbrella" : "Cursor",
                symbol: (settings.weatherMode == .rain || settings.weatherMode == .storm) ? "umbrella.fill" : "cursorarrow.motionlines",
                isOn: $settings.cursorInteraction
            )

            quickPillToggle(
                title: "Surfaces",
                symbol: "square.stack.3d.up.fill",
                isOn: $settings.accumulationEnabled
            )

            Button {
                overlayManager.clearAccumulation()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Sweep")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Clear accumulated snowdrifts and surface caps")
        }
    }

    private func quickPillToggle(title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isOn.wrappedValue ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn.wrappedValue ? settings.weatherMode.accentColor.opacity(0.24) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isOn.wrappedValue ? settings.weatherMode.accentColor.opacity(0.55) : Color.white.opacity(0.09),
                                lineWidth: 0.8
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 10))
                Text("\(settings.targetFPS) FPS · \(overlayManager.trackedObstacleCount) ledges")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit AliSnow")
        }
        .padding(.top, 2)
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}

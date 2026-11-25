import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case surfaces = "Surfaces"
        case performance = "Performance"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .surfaces: return "square.stack.3d.up.fill"
            case .performance: return "bolt.fill"
            }
        }
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var overlayManager: SnowOverlayManager
    @State private var selectedTab: Tab = .general
    @State private var accessibilityGranted: Bool = DesktopObstacleScanner.isAccessibilityTrusted

    var body: some View {
        VStack(spacing: 0) {
            // Top Alcove-style segmented tab bar
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? settings.weatherMode.accentColor.opacity(0.28) : Color.clear)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            selectedTab == tab ? settings.weatherMode.accentColor.opacity(0.6) : Color.clear,
                                            lineWidth: 0.9
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().opacity(0.35)

            ScrollView {
                VStack(spacing: 14) {
                    switch selectedTab {
                    case .general:
                        generalSection
                    case .surfaces:
                        surfacesSection
                    case .performance:
                        performanceSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 470, height: 390)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .onAppear {
            accessibilityGranted = DesktopObstacleScanner.isAccessibilityTrusted
        }
    }

    private var generalSection: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Startup & Display") {
                Toggle("Launch AliSnow at Login", isOn: $settings.launchAtLogin)
                Divider().opacity(0.25)
                Toggle("Render Above All Windows", isOn: $settings.overlayAboveWindows)
                Text(
                    settings.overlayAboveWindows
                        ? "Weather falls across your entire screen over open apps."
                        : "Weather stays right above your desktop wallpaper & icons, behind open windows."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsCard(title: "Interaction") {
                Toggle("Cursor Wind & Umbrella Shield", isOn: $settings.cursorInteraction)
                Text("Move your cursor to part snow, swirl petals/fireflies, shield against rain, or brush away snowdrifts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    settings.resetDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var surfacesSection: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Accumulation & Collisions") {
                Toggle("Enable Drifts, Petals & Splashes", isOn: $settings.accumulationEnabled)
                Divider().opacity(0.25)
                Toggle("Land on Open Window Tops", isOn: $settings.windowTopsEnabled)
                    .disabled(!settings.accumulationEnabled)
                Toggle("Land on Finder Desktop Folders", isOn: $settings.desktopFoldersEnabled)
                    .disabled(!settings.accumulationEnabled)
            }

            settingsCard(title: "Finder Desktop Folders Access") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.seal.fill" : "lock.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(accessibilityGranted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessibilityGranted ? "Accessibility Permission Granted" : "Accessibility Needed for Desktop Icons")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(
                            accessibilityGranted
                                ? "AliSnow can read Finder icon positions and rest snow caps on your folders."
                                : "Window tops & bottom drifts already work with zero permissions. Grant Accessibility to also detect Finder desktop folders."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !accessibilityGranted {
                    HStack(spacing: 8) {
                        Button("Request Permission") {
                            DesktopObstacleScanner.promptForAccessibilityPermission()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                accessibilityGranted = DesktopObstacleScanner.isAccessibilityTrusted
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.weatherMode.accentColor)
                        .controlSize(.small)

                        Button("Open System Settings") {
                            DesktopObstacleScanner.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Refresh") {
                            accessibilityGranted = DesktopObstacleScanner.isAccessibilityTrusted
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }

            HStack {
                Text("Currently tracking \(overlayManager.trackedObstacleCount) surface ledges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Accumulation Now") {
                    overlayManager.clearAccumulation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var performanceSection: some View {
        VStack(spacing: 12) {
            settingsCard(title: "Frame Rate & Energy") {
                HStack {
                    Text("Target Frame Rate")
                    Spacer()
                    Picker("Target Frame Rate", selection: $settings.targetFPS) {
                        Text("30 FPS (Eco)").tag(30)
                        Text("60 FPS").tag(60)
                        Text("120 FPS").tag(120)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                Divider().opacity(0.25)

                Toggle("Auto-throttle to 30 FPS in Low Power Mode", isOn: $settings.autoThrottleLowPower)
            }

            settingsCard(title: "Live GPU Telemetry") {
                HStack(spacing: 12) {
                    telemetryTile(
                        label: "Particles",
                        value: "\(overlayManager.activeParticleCount)",
                        icon: "sparkles"
                    )
                    telemetryTile(
                        label: "Surfaces",
                        value: "\(overlayManager.trackedObstacleCount)",
                        icon: "macwindow"
                    )
                    telemetryTile(
                        label: "State",
                        value: settings.isActive ? "Metal GPU" : "Paused 0%",
                        icon: "cpu"
                    )
                }
            }
        }
    }

    private func telemetryTile(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7)
                    )
            )
        }
    }
}

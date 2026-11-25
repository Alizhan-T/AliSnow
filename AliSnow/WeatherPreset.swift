import Foundation
import ServiceManagement
import SwiftUI

enum AccumulationStyle {
    case snowdrift
    case splash
    case petals
    case leaves
    case none
}

enum WeatherMode: String, CaseIterable, Identifiable, Codable {
    case snow
    case blizzard
    case rain
    case storm
    case sakura
    case autumn
    case fireflies

    var id: String { rawValue }

    var shaderIndex: UInt32 {
        switch self {
        case .snow: return 0
        case .blizzard: return 1
        case .rain: return 2
        case .storm: return 3
        case .sakura: return 4
        case .autumn: return 5
        case .fireflies: return 6
        }
    }

    var title: String {
        switch self {
        case .snow: return "Snow"
        case .blizzard: return "Blizzard"
        case .rain: return "Rain"
        case .storm: return "Storm"
        case .sakura: return "Sakura"
        case .autumn: return "Autumn"
        case .fireflies: return "Fireflies"
        }
    }

    var subtitle: String {
        switch self {
        case .snow: return "Cozy snowfall & drifts"
        case .blizzard: return "Heavy wind gusts"
        case .rain: return "Umbrella cursor & splashes"
        case .storm: return "Downpour & lightning"
        case .sakura: return "Floating cherry petals"
        case .autumn: return "Warm falling leaves"
        case .fireflies: return "Dreamy night glow"
        }
    }

    var symbolName: String {
        switch self {
        case .snow: return "snowflake"
        case .blizzard: return "wind.snow"
        case .rain: return "cloud.rain.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .sakura: return "camera.macro"
        case .autumn: return "leaf.fill"
        case .fireflies: return "sparkles"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .snow: return "snowflake"
        case .blizzard: return "wind.snow"
        case .rain: return "cloud.rain"
        case .storm: return "cloud.bolt.rain"
        case .sakura: return "camera.macro"
        case .autumn: return "leaf"
        case .fireflies: return "sparkles"
        }
    }

    var accentColor: Color {
        switch self {
        case .snow: return Color(red: 0.62, green: 0.84, blue: 1.0)
        case .blizzard: return Color(red: 0.50, green: 0.78, blue: 0.98)
        case .rain: return Color(red: 0.36, green: 0.68, blue: 0.98)
        case .storm: return Color(red: 0.56, green: 0.52, blue: 1.0)
        case .sakura: return Color(red: 1.0, green: 0.66, blue: 0.80)
        case .autumn: return Color(red: 0.98, green: 0.58, blue: 0.24)
        case .fireflies: return Color(red: 0.96, green: 0.86, blue: 0.38)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .snow: return Color(red: 0.32, green: 0.52, blue: 0.78)
        case .blizzard: return Color(red: 0.24, green: 0.44, blue: 0.72)
        case .rain: return Color(red: 0.16, green: 0.34, blue: 0.62)
        case .storm: return Color(red: 0.24, green: 0.22, blue: 0.52)
        case .sakura: return Color(red: 0.82, green: 0.38, blue: 0.58)
        case .autumn: return Color(red: 0.74, green: 0.26, blue: 0.16)
        case .fireflies: return Color(red: 0.34, green: 0.72, blue: 0.48)
        }
    }

    var defaultIntensity: Double {
        switch self {
        case .snow: return 0.60
        case .blizzard: return 0.92
        case .rain: return 0.68
        case .storm: return 0.95
        case .sakura: return 0.45
        case .autumn: return 0.40
        case .fireflies: return 0.35
        }
    }

    var defaultWind: Double {
        switch self {
        case .snow: return 0.20
        case .blizzard: return 1.45
        case .rain: return 0.35
        case .storm: return 0.95
        case .sakura: return 0.55
        case .autumn: return 0.45
        case .fireflies: return 0.05
        }
    }

    var accumulationStyle: AccumulationStyle {
        switch self {
        case .snow, .blizzard: return .snowdrift
        case .rain, .storm: return .splash
        case .sakura: return .petals
        case .autumn: return .leaves
        case .fireflies: return .none
        }
    }

    var supportsAccumulation: Bool {
        accumulationStyle != .none
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let weatherMode = "AliSnow.weatherMode"
        static let isActive = "AliSnow.isActive"
        static let intensity = "AliSnow.intensity"
        static let windStrength = "AliSnow.windStrength"
        static let cursorInteraction = "AliSnow.cursorInteraction"
        static let accumulationEnabled = "AliSnow.accumulationEnabled"
        static let desktopFoldersEnabled = "AliSnow.desktopFoldersEnabled"
        static let windowTopsEnabled = "AliSnow.windowTopsEnabled"
        static let targetFPS = "AliSnow.targetFPS"
        static let autoThrottleLowPower = "AliSnow.autoThrottleLowPower"
        static let overlayAboveWindows = "AliSnow.overlayAboveWindows"
    }

    private let defaults = UserDefaults.standard

    @Published var weatherMode: WeatherMode {
        didSet { defaults.set(weatherMode.rawValue, forKey: Keys.weatherMode) }
    }
    @Published var isActive: Bool {
        didSet { defaults.set(isActive, forKey: Keys.isActive) }
    }
    @Published var intensity: Double {
        didSet { defaults.set(intensity, forKey: Keys.intensity) }
    }
    @Published var windStrength: Double {
        didSet { defaults.set(windStrength, forKey: Keys.windStrength) }
    }
    @Published var cursorInteraction: Bool {
        didSet { defaults.set(cursorInteraction, forKey: Keys.cursorInteraction) }
    }
    @Published var accumulationEnabled: Bool {
        didSet { defaults.set(accumulationEnabled, forKey: Keys.accumulationEnabled) }
    }
    @Published var desktopFoldersEnabled: Bool {
        didSet { defaults.set(desktopFoldersEnabled, forKey: Keys.desktopFoldersEnabled) }
    }
    @Published var windowTopsEnabled: Bool {
        didSet { defaults.set(windowTopsEnabled, forKey: Keys.windowTopsEnabled) }
    }
    @Published var targetFPS: Int {
        didSet { defaults.set(targetFPS, forKey: Keys.targetFPS) }
    }
    @Published var autoThrottleLowPower: Bool {
        didSet { defaults.set(autoThrottleLowPower, forKey: Keys.autoThrottleLowPower) }
    }
    @Published var overlayAboveWindows: Bool {
        didSet { defaults.set(overlayAboveWindows, forKey: Keys.overlayAboveWindows) }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin(launchAtLogin) }
    }

    init() {
        let savedMode = defaults.string(forKey: Keys.weatherMode).flatMap(WeatherMode.init(rawValue:)) ?? .snow
        self.weatherMode = savedMode
        self.isActive = defaults.object(forKey: Keys.isActive) as? Bool ?? true
        self.intensity = defaults.object(forKey: Keys.intensity) as? Double ?? savedMode.defaultIntensity
        self.windStrength = defaults.object(forKey: Keys.windStrength) as? Double ?? savedMode.defaultWind
        self.cursorInteraction = defaults.object(forKey: Keys.cursorInteraction) as? Bool ?? true
        self.accumulationEnabled = defaults.object(forKey: Keys.accumulationEnabled) as? Bool ?? true
        self.desktopFoldersEnabled = defaults.object(forKey: Keys.desktopFoldersEnabled) as? Bool ?? true
        self.windowTopsEnabled = defaults.object(forKey: Keys.windowTopsEnabled) as? Bool ?? true
        self.targetFPS = defaults.object(forKey: Keys.targetFPS) as? Int ?? 60
        self.autoThrottleLowPower = defaults.object(forKey: Keys.autoThrottleLowPower) as? Bool ?? true
        self.overlayAboveWindows = defaults.object(forKey: Keys.overlayAboveWindows) as? Bool ?? true
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func selectMode(_ mode: WeatherMode) {
        weatherMode = mode
        intensity = mode.defaultIntensity
        windStrength = mode.defaultWind
    }

    func resetDefaults() {
        selectMode(.snow)
        isActive = true
        cursorInteraction = true
        accumulationEnabled = true
        desktopFoldersEnabled = true
        windowTopsEnabled = true
        targetFPS = 60
        autoThrottleLowPower = true
        overlayAboveWindows = true
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("AliSnow: Launch at login update failed: \(error)")
        }
    }
}

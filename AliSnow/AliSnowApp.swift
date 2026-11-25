import AppKit
import Combine
import MetalKit
import SwiftUI

@MainActor
final class SnowOverlayManager: ObservableObject {
    @Published private(set) var trackedObstacleCount: Int = 0
    @Published private(set) var activeParticleCount: Int = 0

    private let settings: AppSettings
    private var overlayWindows: [NSWindow] = []
    private var renderers: [SnowRenderer] = []
    private var cancellables: Set<AnyCancellable> = []
    private nonisolated(unsafe) var obstacleTask: Task<Void, Never>?
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    private nonisolated(unsafe) var powerObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        setupOverlays()
        bindSettings()
        startObstacleTracking()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupOverlays()
            }
        }

        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applySettings()
            }
        }
    }

    deinit {
        obstacleTask?.cancel()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = powerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func clearAccumulation() {
        for renderer in renderers {
            renderer.clearAccumulation()
        }
    }

    private func bindSettings() {
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applySettings()
                }
            }
            .store(in: &cancellables)
    }

    private func setupOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        renderers.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: screen.frame.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = resolvedWindowLevel()
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            window.isReleasedWhenClosed = false

            let mtkView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size))
            mtkView.autoresizingMask = [.width, .height]
            mtkView.wantsLayer = true
            mtkView.layer?.isOpaque = false
            mtkView.layer?.backgroundColor = NSColor.clear.cgColor

            if let renderer = SnowRenderer(mtkView: mtkView) {
                renderers.append(renderer)
            }

            window.contentView = mtkView
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlayWindows.append(window)
        }

        applySettings()
    }

    private func resolvedWindowLevel() -> NSWindow.Level {
        if settings.overlayAboveWindows {
            return .statusBar
        }
        // Sit right above Finder desktop icons, behind normal application windows
        return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func applySettings() {
        let level = resolvedWindowLevel()
        for window in overlayWindows {
            if window.level != level {
                window.level = level
            }
        }

        for renderer in renderers {
            renderer.weatherMode = settings.weatherMode
            renderer.isSnowing = settings.isActive
            renderer.cursorInteractionEnabled = settings.cursorInteraction
            renderer.accumulationEnabled = settings.accumulationEnabled
            renderer.intensity = settings.intensity
            renderer.windStrength = Float(settings.windStrength)
            renderer.updateTargetFPS(settings.targetFPS, autoThrottleLowPower: settings.autoThrottleLowPower)
        }

        activeParticleCount = renderers.first?.activeParticlesReadout ?? 0
    }

    private func startObstacleTracking() {
        obstacleTask?.cancel()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        obstacleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let shouldScan = self.settings.isActive
                    && self.settings.accumulationEnabled
                    && self.settings.weatherMode.supportsAccumulation
                    && (self.settings.desktopFoldersEnabled || self.settings.windowTopsEnabled)

                if shouldScan {
                    let includeFolders = self.settings.desktopFoldersEnabled
                    let includeWindows = self.settings.windowTopsEnabled
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
                    let snapshots: [ScreenDisplaySnapshot] = self.overlayWindows.map { win in
                        let frame = win.screen?.frame ?? win.frame
                        let scale = win.screen?.backingScaleFactor ?? win.backingScaleFactor
                        return ScreenDisplaySnapshot(
                            screenFrame: frame,
                            primaryScreenHeight: primaryHeight,
                            backingScale: scale
                        )
                    }

                    let scannedPerScreen: [[ObstacleRect]] = await Task.detached(priority: .utility) {
                        snapshots.map { snap in
                            DesktopObstacleScanner.scanObstacles(
                                for: snap,
                                includeDesktopFolders: includeFolders,
                                includeWindowTops: includeWindows,
                                ownProcessID: ownPID
                            )
                        }
                    }.value

                    var total = 0
                    for (index, rects) in scannedPerScreen.enumerated() where index < self.renderers.count {
                        self.renderers[index].updateObstacles(rects)
                        total += rects.count
                    }
                    self.trackedObstacleCount = total
                } else {
                    for renderer in self.renderers {
                        renderer.updateObstacles([])
                    }
                    self.trackedObstacleCount = 0
                }

                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }
}

@main
struct AliSnowApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var overlayManager: SnowOverlayManager

    init() {
        let appSettings = AppSettings()
        _settings = StateObject(wrappedValue: appSettings)
        _overlayManager = StateObject(wrappedValue: SnowOverlayManager(settings: appSettings))
    }

    var body: some Scene {
        MenuBarExtra(
            "AliSnow",
            systemImage: settings.isActive ? settings.weatherMode.menuBarSymbol : "snowflake.slash"
        ) {
            MenuBarHUDView(settings: settings, overlayManager: overlayManager)
        }
        .menuBarExtraStyle(.window)

        Window("AliSnow Settings", id: "settings") {
            SettingsView(settings: settings, overlayManager: overlayManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

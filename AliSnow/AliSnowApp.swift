import AppKit
import MetalKit
import SwiftUI

@MainActor
final class SnowOverlayManager: ObservableObject {
    @Published var isSnowing: Bool = true {
        didSet { applySettings() }
    }
    @Published var cursorInteractionEnabled: Bool = true {
        didSet { applySettings() }
    }
    @Published var intensity: Double = 0.65 {
        didSet { applySettings() }
    }
    @Published var windStrength: Double = 0.25 {
        didSet { applySettings() }
    }

    private var overlayWindows: [NSWindow] = []
    private var renderers: [SnowRenderer] = []
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    init() {
        setupOverlays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupOverlays()
            }
        }
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
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

    private func applySettings() {
        for renderer in renderers {
            renderer.isSnowing = isSnowing
            renderer.cursorInteractionEnabled = cursorInteractionEnabled
            renderer.intensity = intensity
            renderer.windStrength = Float(windStrength)
        }
    }
}

@main
struct AliSnowApp: App {
    @StateObject private var overlayManager = SnowOverlayManager()

    var body: some Scene {
        MenuBarExtra("AliSnow", systemImage: "snowflake") {
            VStack(alignment: .leading, spacing: 10) {
                Text("AliSnow")
                    .font(.headline)

                Toggle("Идёт снег", isOn: $overlayManager.isSnowing)
                Toggle("Реакция на курсор", isOn: $overlayManager.cursorInteractionEnabled)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Интенсивность: \(Int(overlayManager.intensity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $overlayManager.intensity, in: 0.1...1.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ветер: \(String(format: "%.1f", overlayManager.windStrength))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $overlayManager.windStrength, in: -2.0...2.0)
                }

                Divider()

                Button("Выход") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 220)
        }
        .menuBarExtraStyle(.window)
    }
}

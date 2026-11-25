import AppKit
import ApplicationServices
import CoreGraphics
import simd

struct ObstacleRect: Equatable, Sendable {
    /// Bounds in Metal pixel coordinates (origin top-left of the screen): x, y, width, height
    var bounds: SIMD4<Float>
    /// 0 = window top edge, 1 = Finder desktop folder/icon
    var kind: Float
    var padding1: Float = 0
    var padding2: Float = 0
    var padding3: Float = 0
}

struct ScreenDisplaySnapshot: Sendable {
    let screenFrame: CGRect
    let primaryScreenHeight: CGFloat
    let backingScale: CGFloat
}

enum DesktopObstacleScanner {
    static let maxObstacles = 64

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func scanObstacles(
        for snapshot: ScreenDisplaySnapshot,
        includeDesktopFolders: Bool,
        includeWindowTops: Bool,
        ownProcessID: pid_t
    ) -> [ObstacleRect] {
        var results: [ObstacleRect] = []
        results.reserveCapacity(maxObstacles)

        // Screen bounds in global top-left Quartz coordinates
        let screenQuartzRect = CGRect(
            x: snapshot.screenFrame.origin.x,
            y: snapshot.primaryScreenHeight - snapshot.screenFrame.maxY,
            width: snapshot.screenFrame.width,
            height: snapshot.screenFrame.height
        )

        if includeDesktopFolders {
            let folderRects = scanFinderDesktopIcons()
            for quartzRect in folderRects where results.count < maxObstacles {
                if let local = convertQuartzRectToMetalPixels(
                    quartzRect: quartzRect,
                    screenQuartzRect: screenQuartzRect,
                    scale: snapshot.backingScale
                ) {
                    results.append(ObstacleRect(bounds: local, kind: 1.0))
                }
            }
        }

        if includeWindowTops {
            let windowRects = scanVisibleWindows(ownProcessID: ownProcessID)
            for quartzRect in windowRects where results.count < maxObstacles {
                if let local = convertQuartzRectToMetalPixels(
                    quartzRect: quartzRect,
                    screenQuartzRect: screenQuartzRect,
                    scale: snapshot.backingScale
                ) {
                    results.append(ObstacleRect(bounds: local, kind: 0.0))
                }
            }
        }

        return results
    }

    private static func convertQuartzRectToMetalPixels(
        quartzRect: CGRect,
        screenQuartzRect: CGRect,
        scale: CGFloat
    ) -> SIMD4<Float>? {
        let clipped = quartzRect.intersection(screenQuartzRect)
        guard !clipped.isNull, clipped.width >= 24, clipped.height >= 20 else {
            return nil
        }

        // Ignore items touching the very top menu bar edge
        let localX = clipped.origin.x - screenQuartzRect.origin.x
        let localY = clipped.origin.y - screenQuartzRect.origin.y
        if localY < 26 || localY > screenQuartzRect.height - 20 {
            return nil
        }

        return SIMD4<Float>(
            Float(localX * scale),
            Float(localY * scale),
            Float(clipped.width * scale),
            Float(clipped.height * scale)
        )
    }

    /// Reads visible normal-layer app windows using CoreGraphics (requires zero permissions).
    private static func scanVisibleWindows(ownProcessID: pid_t) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var rects: [CGRect] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownProcessID {
                continue
            }
            if let owner = info[kCGWindowOwnerName as String] as? String,
               owner == "Window Server" || owner == "Dock" || owner == "Control Center" || owner == "Notification Center" {
                continue
            }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.2 {
                continue
            }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }
            if rect.width < 120 || rect.height < 60 {
                continue
            }
            // Skip full-screen backdrop windows (like Finder Desktop window)
            if rect.origin.y <= 1 && rect.height >= 850 && rect.width >= 1200 {
                if let owner = info[kCGWindowOwnerName as String] as? String, owner == "Finder" {
                    continue
                }
            }
            rects.append(rect)
            if rects.count >= 24 {
                break
            }
        }
        return rects
    }

    /// Reads Finder Desktop icon bounding boxes via Accessibility API when granted.
    private static func scanFinderDesktopIcons() -> [CGRect] {
        guard AXIsProcessTrusted() else {
            return []
        }

        guard let finderApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else {
            return []
        }

        let appElement = AXUIElementCreateApplication(finderApp.processIdentifier)
        var windowsValue: CFTypeRef?
        let winResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        var candidateRoots: [AXUIElement] = []

        // Finder's desktop container may appear as a child of the app element or inside AXScrollArea
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                if axRole(of: child) == (kAXScrollAreaRole as String) {
                    candidateRoots.append(child)
                }
            }
        }
        if winResult == .success, let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                if axSubrole(of: window) == "AXDesktopWindow" || axTitle(of: window)?.isEmpty == true {
                    candidateRoots.append(window)
                }
            }
        }

        var iconRects: [CGRect] = []
        var visited = 0
        for root in candidateRoots {
            collectDesktopIcons(from: root, depth: 0, visited: &visited, into: &iconRects)
            if iconRects.count >= 40 {
                break
            }
        }
        return iconRects
    }

    private static func collectDesktopIcons(
        from element: AXUIElement,
        depth: Int,
        visited: inout Int,
        into results: inout [CGRect]
    ) {
        if depth > 4 || visited > 300 || results.count >= 40 {
            return
        }
        visited += 1

        let role = axRole(of: element)
        if role == (kAXGroupRole as String) || role == "AXIcon" || role == (kAXImageRole as String) {
            if let rect = axFrame(of: element),
               rect.width >= 32 && rect.width <= 180 && rect.height >= 32 && rect.height <= 180 {
                // Tighten top surface slightly to match the visual folder icon inside the selection cell
                let capRect = CGRect(
                    x: rect.origin.x + rect.width * 0.14,
                    y: rect.origin.y + 4,
                    width: rect.width * 0.72,
                    height: rect.height * 0.65
                )
                results.append(capRect)
                return
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else {
            return
        }

        for child in children {
            collectDesktopIcons(from: child, depth: depth + 1, visited: &visited, into: &results)
            if results.count >= 40 {
                break
            }
        }
    }

    private static func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axSubrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axTitle(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posCF = posValue, CFGetTypeID(posCF) == AXValueGetTypeID(),
              let sizeCF = sizeValue, CFGetTypeID(sizeCF) == AXValueGetTypeID()
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let posAX = unsafeDowncast(posCF, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeCF, to: AXValue.self)
        guard AXValueGetValue(posAX, .cgPoint, &origin),
              AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }
}

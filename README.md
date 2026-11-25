# AliSnow

A native macOS atmospheric weather overlay powered by **Metal** and **SwiftUI** — designed with an Alcove-inspired dark glass Menu Bar HUD, 7 GPU-accelerated weather vibes, interactive cursor physics, and live snow/petal accumulation on screen edges, windows, and Finder desktop folders.

## Weather Modes

| Mode | Visual Vibe & Physics |
| :--- | :--- |
| **Snow** | Soft glowing snowflakes with 6-point crystal glint, depth parallax, and sculpted snowdrifts. |
| **Blizzard** | Gusting horizontal wind waves, dense fast-moving snow, and rapid drift buildup. |
| **Rain** | Velocity-stretched rain streaks, invisible **cursor umbrella shield**, and splash bursts on surfaces. |
| **Storm** | Heavy downpour with wind gusts, intense splashes, and subtle atmospheric lightning flashes. |
| **Sakura** | Tumbling cherry blossom petals with 3D flutter oscillation and soft pink fallen petal carpets. |
| **Autumn** | Warm gold, amber, and crimson falling leaves gliding gently onto ledges and the bottom edge. |
| **Fireflies** | Dreamy night glow with pulsing warm-gold and mint bokeh orbs swirling around your cursor. |

## Features

- **Alcove-Style Menu Bar HUD** — dark translucent glass popover with dynamic mode-tinted glow, tactile weather cards, intensity & wind sliders, quick toggles, and instant drift sweep.
- **Surface Accumulation & Collisions** — snowdrifts, fallen petals/leaves, and rain splashes collect along the bottom edge of the screen, on top of open application windows (zero permissions needed), and on **Finder desktop folders** (via Accessibility permission). Sweep your cursor across drifts or folder caps to brush them away!
- **Native Settings Window** — configure Launch at Login, overlay layer (above all windows vs. desktop-only), surface collision sources, Accessibility status, and frame rate (30 / 60 / 120 FPS).
- **Zero-Idle Efficiency** — Metal compute + instanced quad rendering (< 0.5 ms GPU/frame), real `MTKView` suspension when paused (**0% CPU/GPU**), and automatic 30 FPS throttling in macOS Low Power Mode.
- **App Sandbox Disabled** — ready for direct macOS distribution and Finder desktop integration.

## Requirements

- macOS 14.0+
- Xcode 16+ (tested on Xcode 27.2 / Apple Silicon)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) *(optional, for regenerating `.xcodeproj` from `project.yml`)*

## Getting Started

### Using Xcode
```bash
open AliSnow.xcodeproj
```
Press **Cmd + R** — your desktop atmosphere starts immediately and the live weather icon appears in the Menu Bar.

### Using Terminal (`xcodebuild`)
```bash
xcodebuild -project AliSnow.xcodeproj -scheme AliSnow -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AliSnow.app
```

> **Note:** `SnowShaders.metal` is bundled as a resource and compiled via macOS's built-in runtime Metal compiler at launch (preferring `default.metallib` if `MetalToolchain` is installed), so the project builds cleanly without extra Xcode downloads.

## Project Structure

```text
AliSnow/
├── AliSnowApp.swift             # App entry point, MenuBarExtra, Settings window, overlay manager
├── WeatherPreset.swift          # 7 weather modes, palettes, defaults, persistent AppSettings
├── MenuBarHUDView.swift         # Alcove-inspired dark glass Menu Bar HUD
├── SettingsView.swift           # Native macOS Settings window (General, Surfaces, Performance)
├── DesktopObstacleTracker.swift # Background scanner for Finder desktop folders & window tops
├── SnowRenderer.swift           # Metal compute/render pipelines, accumulation & real pause
├── SnowShaders.metal            # 7-mode GPU physics, instanced quads, snowdrifts & lightning
└── Assets.xcassets              # App icon and accent color assets
AliSnow.xcodeproj/               # macOS SwiftUI Xcode project (App Sandbox disabled)
project.yml                      # XcodeGen specification
```

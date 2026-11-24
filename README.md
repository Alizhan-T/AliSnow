# AliSnow

A native macOS desktop snow overlay powered by **Metal** and **SwiftUI**. Snowfall physics and rendering run entirely on the GPU, react smoothly to cursor movement, and are controlled from the Menu Bar.

## Features

- **GPU-Accelerated Metal Simulation** — up to 2,500 snowflakes with depth parallax, gentle horizontal sway, configurable wind, and soft glowing particles.
- **Cursor Interaction** — moving the cursor repels nearby snowflakes and creates a directional wind wake across all apps (no extra permissions required).
- **Transparent Click-Through Overlay** — borderless full-screen overlay that ignores mouse events and spans all displays and Spaces.
- **Menu Bar Controls** — lightweight Menu Bar accessory (`LSUIElement`, no Dock icon) with a snowflake icon to toggle snowfall, cursor interaction, intensity, and wind strength.
- **App Sandbox Disabled** — preconfigured without App Sandbox to support upcoming desktop Finder folder collision & snow accumulation.

## Requirements

- macOS 14.0+
- Xcode 16+ (tested on Xcode 27.2 / Apple Silicon)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) *(optional, if regenerating `.xcodeproj` from `project.yml`)*

## Getting Started

### Using Xcode
1. Open the project:
   ```bash
   open AliSnow.xcodeproj
   ```
2. Press **Cmd + R** — snow will start falling over your screen and a snowflake icon will appear in the Menu Bar.

### Using Terminal (`xcodebuild`)
```bash
xcodebuild -project AliSnow.xcodeproj -scheme AliSnow -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AliSnow.app
```

> **Note:** `SnowShaders.metal` is bundled as an app resource and compiled via macOS's built-in runtime Metal compiler at launch (automatically preferring `default.metallib` if `MetalToolchain` is installed). This allows immediate builds and runs without downloading extra Xcode components.

## Project Structure

```text
AliSnow/
├── AliSnowApp.swift        # Entry point, MenuBarExtra UI, and transparent NSWindow overlays
├── SnowRenderer.swift      # MTKViewDelegate, Metal pipelines, and global cursor tracking
├── SnowShaders.metal       # GPU compute shader (updateSnow) + vertex/fragment shaders
└── Assets.xcassets         # App icon and accent color assets
AliSnow.xcodeproj/          # macOS SwiftUI Xcode project (App Sandbox disabled)
project.yml                 # XcodeGen specification
```

## Performance

- **Particle Buffer:** `2,500 × 32 bytes ≈ 78 KB` plus `48 bytes` of per-frame uniforms.
- **GPU Work:** `1 compute dispatch` + `1 draw call` (`.point` primitives), taking **< 0.3 ms/frame** on Apple Silicon.
- **CPU Usage:** ~1–3% at 60 FPS (all simulation and rendering runs on the GPU).
- **Memory Footprint:** ~50–90 MB total (primarily the full-screen transparent `MTKView` drawable buffers).

## Roadmap

- [x] **Stage 1:** Base macOS Xcode project without Sandbox, Metal snowfall with cursor interaction, Menu Bar controls.
- [ ] **Stage 2:** Snowdrifts and snow accumulation on Finder desktop folders and icons.
- [ ] **Stage 3:** Power optimizations (pause `MTKView` at 0% idle usage, 30/60 FPS selector, Low Power Mode throttling).

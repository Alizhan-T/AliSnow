import AppKit
import Metal
import MetalKit
import simd

struct WeatherParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var depth: Float
    var phase: Float
    var alpha: Float
    var rotation: Float
    var spinSpeed: Float
    var colorVariant: Float
    var splashTimer: Float
}

struct WeatherUniforms {
    var viewportSize: SIMD2<Float>
    var mousePosition: SIMD2<Float>
    var mouseVelocity: SIMD2<Float>
    var deltaTime: Float
    var time: Float
    var windStrength: Float
    var cursorRadius: Float
    var cursorEnabled: Float
    var backingScale: Float
    var lightningFlash: Float
    var accumulationEnabled: Float
    var particleCount: UInt32
    var weatherMode: UInt32
    var obstacleCount: UInt32
    var heightmapBins: UInt32
}

@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private static let heightmapBinCount = 256
    private static let maxObstacles = DesktopObstacleScanner.maxObstacles

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let updatePipeline: MTLComputePipelineState
    private let smoothPipeline: MTLComputePipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let bottomDriftPipeline: MTLRenderPipelineState
    private let obstacleCapPipeline: MTLRenderPipelineState
    private let atmospherePipeline: MTLRenderPipelineState

    private let particleBuffer: MTLBuffer
    private let obstacleBuffer: MTLBuffer
    private let bottomHeightmapBuffer: MTLBuffer
    private let smoothedBottomBuffer: MTLBuffer
    private let obstacleCapsBuffer: MTLBuffer
    private let smoothedCapsBuffer: MTLBuffer

    private weak var mtkView: MTKView?
    private let maxParticleCount: Int
    private var activeParticleCount: Int
    private var viewportSize: SIMD2<Float> = .zero
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var elapsedTime: Float = 0
    private var lastMousePosition: SIMD2<Float>?
    private var smoothedMouseVelocity: SIMD2<Float> = .zero

    private var obstacleCount: Int = 0
    private var lightningFlash: Float = 0
    private var nextLightningTime: Float = 5.0
    private var needsClearFrameBeforePause = false

    var weatherMode: WeatherMode = .snow {
        didSet {
            if weatherMode != oldValue {
                clearAccumulation()
                resetSplashTimers()
            }
        }
    }

    var isSnowing: Bool = true {
        didSet {
            if isSnowing {
                lastFrameTime = CACurrentMediaTime()
                needsClearFrameBeforePause = false
                mtkView?.isPaused = false
            } else {
                // Draw one clean transparent frame, then pause MTKView (0% CPU/GPU)
                needsClearFrameBeforePause = true
                mtkView?.isPaused = false
            }
        }
    }

    var cursorInteractionEnabled: Bool = true
    var accumulationEnabled: Bool = true
    var windStrength: Float = 0.25
    var cursorRadiusPoints: Float = 135.0
    var intensity: Double = 0.60 {
        didSet {
            let clamped = max(0.08, min(1.0, intensity))
            let modeScale: Double = (weatherMode == .fireflies) ? 0.14 : 1.0
            activeParticleCount = max(45, Int(Double(maxParticleCount) * clamped * modeScale))
        }
    }

    var activeParticlesReadout: Int { activeParticleCount }
    var trackedObstaclesReadout: Int { obstacleCount }

    private static func makeShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLibrary = device.makeDefaultLibrary(),
           defaultLibrary.makeFunction(name: "updateWeather") != nil {
            return defaultLibrary
        }
        guard let url = Bundle.main.url(forResource: "SnowShaders", withExtension: "metal") else {
            NSLog("AliSnow: SnowShaders.metal not found in app bundle.")
            return nil
        }
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            NSLog("AliSnow: Failed to compile SnowShaders.metal: \(error)")
            return nil
        }
    }

    private static func makeAlphaBlendedPipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    init?(mtkView: MTKView, maxParticleCount: Int = 2500) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = Self.makeShaderLibrary(device: device),
              let updateFn = library.makeFunction(name: "updateWeather"),
              let smoothFn = library.makeFunction(name: "smoothAccumulation"),
              let particleVert = library.makeFunction(name: "particleVertex"),
              let particleFrag = library.makeFunction(name: "particleFragment"),
              let driftVert = library.makeFunction(name: "bottomDriftVertex"),
              let driftFrag = library.makeFunction(name: "bottomDriftFragment"),
              let capVert = library.makeFunction(name: "obstacleCapVertex"),
              let capFrag = library.makeFunction(name: "obstacleCapFragment"),
              let fullVert = library.makeFunction(name: "fullscreenVertex"),
              let atmoFrag = library.makeFunction(name: "atmosphereFragment")
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.mtkView = mtkView
        self.maxParticleCount = maxParticleCount
        self.activeParticleCount = Int(Double(maxParticleCount) * 0.60)

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.framebufferOnly = true
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        (mtkView.layer as? CAMetalLayer)?.isOpaque = false

        do {
            self.updatePipeline = try device.makeComputePipelineState(function: updateFn)
            self.smoothPipeline = try device.makeComputePipelineState(function: smoothFn)
            self.particlePipeline = try Self.makeAlphaBlendedPipeline(
                device: device, vertex: particleVert, fragment: particleFrag, pixelFormat: mtkView.colorPixelFormat
            )
            self.bottomDriftPipeline = try Self.makeAlphaBlendedPipeline(
                device: device, vertex: driftVert, fragment: driftFrag, pixelFormat: mtkView.colorPixelFormat
            )
            self.obstacleCapPipeline = try Self.makeAlphaBlendedPipeline(
                device: device, vertex: capVert, fragment: capFrag, pixelFormat: mtkView.colorPixelFormat
            )
            self.atmospherePipeline = try Self.makeAlphaBlendedPipeline(
                device: device, vertex: fullVert, fragment: atmoFrag, pixelFormat: mtkView.colorPixelFormat
            )
        } catch {
            NSLog("AliSnow: Failed to create Metal pipeline states: \(error)")
            return nil
        }

        let initialSize = Self.resolveInitialViewportSize(for: mtkView)
        self.viewportSize = initialSize
        let scale = Float(mtkView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        var initialParticles: [WeatherParticle] = []
        initialParticles.reserveCapacity(maxParticleCount)
        for _ in 0..<maxParticleCount {
            let depth = Float.random(in: 0.18...1.0)
            let size = (1.8 + depth * 3.8) * scale
            let fallSpeed = (42.0 + depth * 95.0) * scale
            initialParticles.append(
                WeatherParticle(
                    position: SIMD2<Float>(
                        Float.random(in: 0...max(initialSize.x, 1)),
                        Float.random(in: 0...max(initialSize.y, 1))
                    ),
                    velocity: SIMD2<Float>(Float.random(in: -15...15) * scale, fallSpeed),
                    size: size,
                    depth: depth,
                    phase: Float.random(in: 0...(Float.pi * 2.0)),
                    alpha: 0.35 + depth * 0.6,
                    rotation: Float.random(in: 0...(Float.pi * 2.0)),
                    spinSpeed: Float.random(in: -2.2...2.2),
                    colorVariant: Float.random(in: 0...1),
                    splashTimer: 0
                )
            )
        }

        guard let particleBuf = device.makeBuffer(
                bytes: initialParticles,
                length: MemoryLayout<WeatherParticle>.stride * maxParticleCount,
                options: .storageModeShared
              ),
              let obstacleBuf = device.makeBuffer(
                length: MemoryLayout<ObstacleRect>.stride * Self.maxObstacles,
                options: .storageModeShared
              ),
              let bottomRawBuf = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride * Self.heightmapBinCount,
                options: .storageModeShared
              ),
              let bottomSmoothBuf = device.makeBuffer(
                length: MemoryLayout<Float>.stride * Self.heightmapBinCount,
                options: .storageModeShared
              ),
              let capsRawBuf = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride * Self.maxObstacles,
                options: .storageModeShared
              ),
              let capsSmoothBuf = device.makeBuffer(
                length: MemoryLayout<Float>.stride * Self.maxObstacles,
                options: .storageModeShared
              )
        else {
            return nil
        }

        self.particleBuffer = particleBuf
        self.obstacleBuffer = obstacleBuf
        self.bottomHeightmapBuffer = bottomRawBuf
        self.smoothedBottomBuffer = bottomSmoothBuf
        self.obstacleCapsBuffer = capsRawBuf
        self.smoothedCapsBuffer = capsSmoothBuf

        super.init()

        clearAccumulation()
        mtkView.preferredFramesPerSecond = 60
        mtkView.delegate = self
    }

    private static func resolveInitialViewportSize(for view: MTKView) -> SIMD2<Float> {
        let drawable = view.drawableSize
        if drawable.width > 1 && drawable.height > 1 {
            return SIMD2<Float>(Float(drawable.width), Float(drawable.height))
        }
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return SIMD2<Float>(Float(screenFrame.width * scale), Float(screenFrame.height * scale))
    }

    func updateTargetFPS(_ fps: Int, autoThrottleLowPower: Bool) {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let effectiveFPS = (autoThrottleLowPower && isLowPower) ? min(fps, 30) : fps
        mtkView?.preferredFramesPerSecond = max(24, min(120, effectiveFPS))
    }

    func updateObstacles(_ obstacles: [ObstacleRect]) {
        let count = min(obstacles.count, Self.maxObstacles)
        let dst = obstacleBuffer.contents().bindMemory(to: ObstacleRect.self, capacity: Self.maxObstacles)
        let rawCaps = obstacleCapsBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxObstacles)
        let smoothCaps = smoothedCapsBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxObstacles)

        // Preserve existing snow cap height when an obstacle stays in roughly the same place
        var previousRects: [ObstacleRect] = []
        var previousRawCaps: [UInt32] = []
        var previousSmoothCaps: [Float] = []
        previousRects.reserveCapacity(obstacleCount)
        previousRawCaps.reserveCapacity(obstacleCount)
        previousSmoothCaps.reserveCapacity(obstacleCount)
        for i in 0..<obstacleCount {
            previousRects.append(dst[i])
            previousRawCaps.append(rawCaps[i])
            previousSmoothCaps.append(smoothCaps[i])
        }

        for i in 0..<count {
            let newRect = obstacles[i]
            dst[i] = newRect
            var matchedRaw: UInt32 = 0
            var matchedSmooth: Float = 0
            for j in 0..<previousRects.count {
                let delta = simd_abs(previousRects[j].bounds - newRect.bounds)
                if delta.x < 18 && delta.y < 18 && delta.z < 24 {
                    matchedRaw = previousRawCaps[j]
                    matchedSmooth = previousSmoothCaps[j]
                    break
                }
            }
            rawCaps[i] = matchedRaw
            smoothCaps[i] = matchedSmooth
        }

        if count < Self.maxObstacles {
            for i in count..<Self.maxObstacles {
                rawCaps[i] = 0
                smoothCaps[i] = 0
            }
        }
        obstacleCount = count
    }

    func clearAccumulation() {
        memset(bottomHeightmapBuffer.contents(), 0, bottomHeightmapBuffer.length)
        memset(smoothedBottomBuffer.contents(), 0, smoothedBottomBuffer.length)
        memset(obstacleCapsBuffer.contents(), 0, obstacleCapsBuffer.length)
        memset(smoothedCapsBuffer.contents(), 0, smoothedCapsBuffer.length)
    }

    private func resetSplashTimers() {
        let ptr = particleBuffer.contents().bindMemory(to: WeatherParticle.self, capacity: maxParticleCount)
        for i in 0..<maxParticleCount {
            ptr[i].splashTimer = 0
        }
        // Recalculate active particle count for mode (e.g. fireflies uses fewer, larger glowing orbs)
        let currentIntensity = intensity
        intensity = currentIntensity
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let newSize = SIMD2<Float>(Float(size.width), Float(size.height))
        let oldSize = viewportSize
        viewportSize = newSize

        if oldSize.x > 1 && oldSize.y > 1 {
            let scaleX = newSize.x / oldSize.x
            let scaleY = newSize.y / oldSize.y
            let ptr = particleBuffer.contents().bindMemory(to: WeatherParticle.self, capacity: maxParticleCount)
            for i in 0..<maxParticleCount {
                ptr[i].position.x *= scaleX
                ptr[i].position.y *= scaleY
            }
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240.0), 1.0 / 20.0))
        lastFrameTime = now

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        // If paused, render one empty clear frame and then suspend MTKView completely (0% CPU/GPU)
        if !isSnowing {
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            if needsClearFrameBeforePause {
                needsClearFrameBeforePause = false
                view.isPaused = true
            }
            return
        }

        let drawableSize = view.drawableSize
        if drawableSize.width > 1 && drawableSize.height > 1 {
            viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        }

        let scale = Float(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        let mousePos = currentMousePositionInPixels(in: view, scale: scale)

        if let prev = lastMousePosition {
            let rawVel = (mousePos - prev) / max(dt, 0.001)
            let rawLen = simd_length(rawVel)
            let clampedSpeed = min(rawLen, 2200.0 * scale)
            let clampedVel = rawLen > 0.001 ? (rawVel / rawLen) * clampedSpeed : .zero
            smoothedMouseVelocity = simd_mix(smoothedMouseVelocity, clampedVel, SIMD2<Float>(repeating: 0.35))
        } else {
            smoothedMouseVelocity = .zero
        }
        lastMousePosition = mousePos

        elapsedTime += dt

        // Occasional realistic lightning flash in Storm mode
        if weatherMode == .storm {
            if elapsedTime >= nextLightningTime {
                lightningFlash = Float.random(in: 0.72...1.0)
                nextLightningTime = elapsedTime + Float.random(in: 5.5...13.0)
            } else {
                lightningFlash *= exp(-6.8 * dt)
                if lightningFlash < 0.004 { lightningFlash = 0 }
            }
        } else {
            lightningFlash = 0
        }

        var uniforms = WeatherUniforms(
            viewportSize: viewportSize,
            mousePosition: mousePos,
            mouseVelocity: smoothedMouseVelocity,
            deltaTime: dt,
            time: elapsedTime,
            windStrength: windStrength,
            cursorRadius: cursorRadiusPoints * scale,
            cursorEnabled: cursorInteractionEnabled ? 1.0 : 0.0,
            backingScale: scale,
            lightningFlash: lightningFlash,
            accumulationEnabled: accumulationEnabled ? 1.0 : 0.0,
            particleCount: UInt32(activeParticleCount),
            weatherMode: weatherMode.shaderIndex,
            obstacleCount: UInt32(obstacleCount),
            heightmapBins: UInt32(Self.heightmapBinCount)
        )

        // 1. GPU Compute: Particle Physics + Accumulation Smoothing
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(updatePipeline)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
            computeEncoder.setBuffer(obstacleBuffer, offset: 0, index: 2)
            computeEncoder.setBuffer(bottomHeightmapBuffer, offset: 0, index: 3)
            computeEncoder.setBuffer(obstacleCapsBuffer, offset: 0, index: 4)
            computeEncoder.setBuffer(smoothedBottomBuffer, offset: 0, index: 5)

            let threadsPerGroup = min(updatePipeline.maxTotalThreadsPerThreadgroup, 256)
            computeEncoder.dispatchThreads(
                MTLSize(width: activeParticleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
            )

            computeEncoder.setComputePipelineState(smoothPipeline)
            computeEncoder.setBuffer(bottomHeightmapBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(smoothedBottomBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(obstacleCapsBuffer, offset: 0, index: 2)
            computeEncoder.setBuffer(smoothedCapsBuffer, offset: 0, index: 3)
            computeEncoder.setBuffer(obstacleBuffer, offset: 0, index: 4)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 5)

            let smoothCount = max(Self.heightmapBinCount, max(obstacleCount, 1))
            let smoothGroup = min(smoothPipeline.maxTotalThreadsPerThreadgroup, 64)
            computeEncoder.dispatchThreads(
                MTLSize(width: smoothCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: smoothGroup, height: 1, depth: 1)
            )
            computeEncoder.endEncoding()
        }

        // 2. GPU Render: Lightning Glow -> Bottom Drifts -> Obstacle Caps -> Instanced Weather Particles
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            if lightningFlash > 0.005 {
                renderEncoder.setRenderPipelineState(atmospherePipeline)
                renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 0)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            if accumulationEnabled && weatherMode.supportsAccumulation {
                renderEncoder.setRenderPipelineState(bottomDriftPipeline)
                renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 0)
                renderEncoder.setFragmentBuffer(smoothedBottomBuffer, offset: 0, index: 0)
                renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

                if obstacleCount > 0 {
                    renderEncoder.setRenderPipelineState(obstacleCapPipeline)
                    renderEncoder.setVertexBuffer(obstacleBuffer, offset: 0, index: 0)
                    renderEncoder.setVertexBuffer(smoothedCapsBuffer, offset: 0, index: 1)
                    renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 2)
                    renderEncoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: 0,
                        vertexCount: 6,
                        instanceCount: obstacleCount
                    )
                }
            }

            renderEncoder.setRenderPipelineState(particlePipeline)
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<WeatherUniforms>.stride, index: 1)
            renderEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: activeParticleCount
            )
            renderEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func currentMousePositionInPixels(in view: MTKView, scale: Float) -> SIMD2<Float> {
        guard let window = view.window else {
            return SIMD2<Float>(-10000, -10000)
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = view.convert(windowPoint, from: nil)

        let x = Float(viewPoint.x) * scale
        let y = Float(view.bounds.height - viewPoint.y) * scale
        return SIMD2<Float>(x, y)
    }
}

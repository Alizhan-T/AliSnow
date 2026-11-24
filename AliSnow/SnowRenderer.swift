import AppKit
import Metal
import MetalKit
import simd

struct Snowflake {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var depth: Float
    var phase: Float
    var alpha: Float
}

struct SnowUniforms {
    var viewportSize: SIMD2<Float>
    var mousePosition: SIMD2<Float>
    var mouseVelocity: SIMD2<Float>
    var deltaTime: Float
    var time: Float
    var windStrength: Float
    var cursorRadius: Float
    var cursorEnabled: Float
    var particleCount: UInt32
}

@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let flakeBuffer: MTLBuffer

    private let maxParticleCount: Int
    private var activeParticleCount: Int
    private var viewportSize: SIMD2<Float> = .zero
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var elapsedTime: Float = 0
    private var lastMousePosition: SIMD2<Float>?
    private var smoothedMouseVelocity: SIMD2<Float> = .zero

    var isSnowing: Bool = true
    var cursorInteractionEnabled: Bool = true
    var windStrength: Float = 0.25
    var cursorRadiusPoints: Float = 135.0
    var intensity: Double = 0.65 {
        didSet {
            let clamped = max(0.05, min(1.0, intensity))
            activeParticleCount = max(100, Int(Double(maxParticleCount) * clamped))
        }
    }

    private static func makeShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLibrary = device.makeDefaultLibrary(),
           defaultLibrary.makeFunction(name: "updateSnow") != nil {
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

    init?(mtkView: MTKView, maxParticleCount: Int = 2500) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = Self.makeShaderLibrary(device: device),
              let computeFunction = library.makeFunction(name: "updateSnow"),
              let vertexFunction = library.makeFunction(name: "snowVertex"),
              let fragmentFunction = library.makeFunction(name: "snowFragment")
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.maxParticleCount = maxParticleCount
        self.activeParticleCount = Int(Double(maxParticleCount) * 0.65)

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.framebufferOnly = true
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        (mtkView.layer as? CAMetalLayer)?.isOpaque = false

        do {
            self.computePipeline = try device.makeComputePipelineState(function: computeFunction)

            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.vertexFunction = vertexFunction
            renderDescriptor.fragmentFunction = fragmentFunction
            renderDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            renderDescriptor.colorAttachments[0].isBlendingEnabled = true
            renderDescriptor.colorAttachments[0].rgbBlendOperation = .add
            renderDescriptor.colorAttachments[0].alphaBlendOperation = .add
            // Premultiplied alpha blending
            renderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            renderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            renderDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            renderDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            NSLog("AliSnow: Failed to create Metal pipeline states: \(error)")
            return nil
        }

        let initialSize = Self.resolveInitialViewportSize(for: mtkView)
        self.viewportSize = initialSize

        var initialFlakes: [Snowflake] = []
        initialFlakes.reserveCapacity(maxParticleCount)
        let scale = Float(mtkView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        for _ in 0..<maxParticleCount {
            let depth = Float.random(in: 0.18...1.0)
            let size = (1.6 + depth * 3.8) * scale
            let fallSpeed = (42.0 + depth * 103.0) * scale
            let flake = Snowflake(
                position: SIMD2<Float>(
                    Float.random(in: 0...max(initialSize.x, 1)),
                    Float.random(in: 0...max(initialSize.y, 1))
                ),
                velocity: SIMD2<Float>(Float.random(in: -15...15) * scale, fallSpeed),
                size: size,
                depth: depth,
                phase: Float.random(in: 0...(Float.pi * 2.0)),
                alpha: 0.35 + depth * 0.6
            )
            initialFlakes.append(flake)
        }

        let bufferLength = MemoryLayout<Snowflake>.stride * maxParticleCount
        guard let buffer = device.makeBuffer(bytes: initialFlakes, length: bufferLength, options: .storageModeShared) else {
            return nil
        }
        self.flakeBuffer = buffer

        super.init()

        mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let newSize = SIMD2<Float>(Float(size.width), Float(size.height))
        let oldSize = viewportSize
        viewportSize = newSize

        if oldSize.x > 1 && oldSize.y > 1 {
            let scaleX = newSize.x / oldSize.x
            let scaleY = newSize.y / oldSize.y
            let ptr = flakeBuffer.contents().bindMemory(to: Snowflake.self, capacity: maxParticleCount)
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

        let drawableSize = view.drawableSize
        if drawableSize.width > 1 && drawableSize.height > 1 {
            viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        }

        let scale = Float(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        let mousePos = currentMousePositionInPixels(in: view, scale: scale)

        if let prev = lastMousePosition {
            let rawVel = (mousePos - prev) / max(dt, 0.001)
            let clampedSpeed = min(simd_length(rawVel), 2200.0 * scale)
            let clampedVel = simd_length(rawVel) > 0.001 ? simd_normalize(rawVel) * clampedSpeed : .zero
            smoothedMouseVelocity = simd_mix(smoothedMouseVelocity, clampedVel, SIMD2<Float>(repeating: 0.35))
        } else {
            smoothedMouseVelocity = .zero
        }
        lastMousePosition = mousePos

        if isSnowing {
            elapsedTime += dt
        }

        var uniforms = SnowUniforms(
            viewportSize: viewportSize,
            mousePosition: mousePos,
            mouseVelocity: smoothedMouseVelocity,
            deltaTime: isSnowing ? dt : 0,
            time: elapsedTime,
            windStrength: windStrength * scale,
            cursorRadius: cursorRadiusPoints * scale,
            cursorEnabled: cursorInteractionEnabled ? 1.0 : 0.0,
            particleCount: UInt32(activeParticleCount)
        )

        // 1. Update snow physics on GPU
        if isSnowing, let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(computePipeline)
            computeEncoder.setBuffer(flakeBuffer, offset: 0, index: 0)
            computeEncoder.setBytes(&uniforms, length: MemoryLayout<SnowUniforms>.stride, index: 1)

            let threadsPerGroup = min(computePipeline.maxTotalThreadsPerThreadgroup, 256)
            let threadgroupSize = MTLSize(width: threadsPerGroup, height: 1, depth: 1)
            let gridSize = MTLSize(width: activeParticleCount, height: 1, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
        }

        // 2. Render snow particles over transparent background
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            if isSnowing {
                renderEncoder.setRenderPipelineState(renderPipeline)
                renderEncoder.setVertexBuffer(flakeBuffer, offset: 0, index: 0)
                renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<SnowUniforms>.stride, index: 1)
                renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: activeParticleCount)
            }
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

        // Flip Y from macOS bottom-left to Metal top-left pixel coordinates
        let x = Float(viewPoint.x) * scale
        let y = Float(view.bounds.height - viewPoint.y) * scale
        return SIMD2<Float>(x, y)
    }
}

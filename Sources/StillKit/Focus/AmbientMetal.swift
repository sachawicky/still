import AppKit
import MetalKit
import SwiftUI
import os

/// Shared immutable pipelines: one compilation per process, not per screen or frame.
@MainActor
final class AmbientGPU {
    static let shared = Result { try AmbientGPU() }
    let device: MTLDevice
    let background: MTLRenderPipelineState
    let ribbon: MTLRenderPipelineState
    let depth: MTLDepthStencilState
    static let format: MTLPixelFormat = .bgra8Unorm
    static let segments = 192
    static let crossSegments = 32
    static let vertexCount = segments * crossSegments * 6

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw AmbientError.unavailable }
        self.device = device
        let library = try device.makeLibrary(source: AmbientShader.source, options: nil)
        func pipeline(vertex: String, fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.format
            descriptor.depthAttachmentPixelFormat = .depth32Float
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = blend
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        background = try pipeline(vertex: "backdropVertex", fragment: "backdropFragment", blend: false)
        ribbon = try pipeline(vertex: "ribbonVertex", fragment: "ribbonFragment", blend: true)
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: descriptor)!
    }

    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                size: CGSize, seconds: Double, palette: [SIMD3<Float>], light: Bool = false) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Still · sculptural ribbons"
        var uniforms = AmbientUniforms(viewport: SIMD4(Float(size.width / max(1, size.height)), light ? 1 : 0, 0, 0),
                                       phases: AmbientPolicy.phases(at: seconds),
                                       dark: SIMD4(palette[0], 1), cool: SIMD4(palette[1], 1), warm: SIMD4(palette[2], 1))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AmbientUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AmbientUniforms>.stride, index: 0)
        encoder.setRenderPipelineState(background)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(ribbon)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        // Back-to-front sheets with depth-tested folds. Transparent fragments are
        // discarded before depth writes; grazing contours feather in the shader.
        for layer in 0..<4 {
            var index = UInt32(layer)
            encoder.setVertexBytes(&index, length: 4, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.vertexCount)
        }
        encoder.endEncoding()
    }
}

enum AmbientError: Error { case unavailable }
private struct AmbientUniforms {
    var viewport: SIMD4<Float>
    var phases: SIMD4<Float>
    var dark: SIMD4<Float>
    var cool: SIMD4<Float>
    var warm: SIMD4<Float>
}

struct AmbientMetalView: NSViewRepresentable {
    let theme: AmbientTheme
    let light: Bool
    let framesPerSecond: Double
    func makeNSView(context: Context) -> AmbientMetalSurface {
        let view = AmbientMetalSurface(frame: .zero)
        view.configure(theme: theme, fps: framesPerSecond, light: light)
        return view
    }
    func updateNSView(_ view: AmbientMetalSurface, context: Context) {
        view.configure(theme: theme, fps: framesPerSecond, light: light)
    }
    static func dismantleNSView(_ view: AmbientMetalSurface, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
        view.renderer = nil
        view.releaseDrawables()
    }
}

/// MTKView's display-linked loop never invalidates the SwiftUI wordmark/clock/glass.
/// Occlusion, detachment, display sleep and Focus lifecycle all stop submissions.
@MainActor
final class AmbientMetalSurface: MTKView {
    var renderer: AmbientRenderer?
    private var requestedFPS: Double = 0
    private var configuredTheme: AmbientTheme?
    private var configuredLight = false
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect, device: MTLDevice? = nil) {
        super.init(frame: frame, device: device)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = false
        colorPixelFormat = AmbientGPU.format
        depthStencilPixelFormat = .depth32Float
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        do {
            let gpu = try AmbientGPU.shared.get()
            self.device = gpu.device
            renderer = try AmbientRenderer(gpu: gpu)
            delegate = renderer
        } catch {
            isHidden = true
            Logger(subsystem: "app.still.macos", category: "Ambient").error("Metal unavailable; static palette fallback: \(String(describing: error), privacy: .public)")
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(theme: AmbientTheme, fps: Double, light: Bool = false) {
        guard configuredTheme != theme || requestedFPS != fps || configuredLight != light else { return }
        configuredTheme = theme
        configuredLight = light
        requestedFPS = fps
        renderer?.setTheme(theme, animated: fps > 0, light: light)
        reconcile()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcile() }
                })
            }
        }
        reconcile()
    }
    override func viewDidHide() { super.viewDidHide(); reconcile() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcile() }
    override var frame: NSRect { didSet { updateResolution() } }
    override var bounds: NSRect { didSet { updateResolution() } }
    override func layout() { super.layout(); updateResolution() }
    private func reconcile() {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        let refresh = window?.screen?.maximumFramesPerSecond ?? 60
        preferredFramesPerSecond = max(1, min(refresh, Int(requestedFPS)))
        let shouldAnimate = visible && requestedFPS > 0 && renderer != nil
        renderer?.setAnimating(shouldAnimate)
        isPaused = !shouldAnimate
        enableSetNeedsDisplay = !shouldAnimate
        updateResolution()
        if visible && !shouldAnimate { needsDisplay = true }
        if !visible { releaseDrawables() }
    }
    func updateResolution() {
        guard renderer != nil else { return }
        // NSHostingView can temporarily expose a degenerate backing transform
        // during layout probes. The window's backing scale is stable and exact
        // for this untransformed, full-cover artwork surface.
        let backingScale = window?.backingScaleFactor ?? 1
        let pixels = CGSize(width: bounds.width * backingScale, height: bounds.height * backingScale)
        let size = AmbientPolicy.drawableSize(pixels, constrained: requestedFPS > 0 && requestedFPS <= 12,
                                               scale: renderer?.resolutionScale ?? 1)
        if drawableSize != size {
            drawableSize = size
            if isPaused && window?.isVisible == true { needsDisplay = true }
        }
    }
    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class AmbientRenderer: NSObject, MTKViewDelegate {
    let gpu: AmbientGPU
    let queue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: 2)
    private var lastTick: CFTimeInterval?
    private var elapsed: Double = 0
    private var animating = false
    private var theme: AmbientTheme = .midnight
    private var light = false
    private var sourcePalette = AmbientTheme.midnight.palette
    private var transitionStart: Double = -10
    private(set) var resolutionScale: Double = 1
    private var frame = 0
    private var cheapSamples = 0
    // Enabled only by the developer harness. GPU durations come from completed buffers.
    var onSample: ((Double, CGSize) -> Void)?
    var onPresented: ((Double) -> Void)?
    var submittedFrames: Int { frame }

    init(gpu: AmbientGPU) throws {
        self.gpu = gpu
        guard let queue = gpu.device.makeCommandQueue() else { throw AmbientError.unavailable }
        self.queue = queue
        super.init()
    }
    private func palette() -> [SIMD3<Float>] {
        let x = Float(min(1, max(0, (elapsed - transitionStart) / 1.8)))
        let blend = x * x * (3 - 2 * x)
        return zip(sourcePalette, theme.palette(light: light)).map { $0 + ($1 - $0) * blend }
    }
    func setTheme(_ value: AmbientTheme, animated: Bool, light: Bool = false) {
        guard value != theme || light != self.light else { return }
        sourcePalette = animated ? palette() : value.palette(light: light)
        theme = value
        self.light = light
        transitionStart = animated ? elapsed : elapsed - 10
    }
    func setAnimating(_ value: Bool) {
        guard value != animating else { return }
        animating = value
        lastTick = nil // Never jump forward by the duration of a pause/sleep.
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard view.window?.isVisible == true, view.window?.occlusionState.contains(.visible) == true, !view.isHiddenOrHasHiddenAncestor,
              inFlight.wait(timeout: .now()) == .success else { return }
        // SwiftUI can assign an NSView frame without scheduling AppKit layout.
        // Confirm the backing size before acquiring a drawable, including static draws.
        (view as? AmbientMetalSurface)?.updateResolution()
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let now = CACurrentMediaTime()
        if animating, let lastTick { elapsed += min(0.1, max(0, now - lastTick)) }
        lastTick = animating ? now : nil
        gpu.encode(command: command, pass: pass, size: view.drawableSize, seconds: elapsed, palette: palette(), light: light)
        frame += 1
        let sampled = frame % 30 == 0 || onSample != nil
        let semaphore = inFlight
        let size = view.drawableSize
        let budget = 0.4 / Double(max(1, view.preferredFramesPerSecond))
        command.addCompletedHandler { [weak self, weak view] buffer in
            semaphore.signal()
            if sampled {
                let duration = buffer.gpuEndTime - buffer.gpuStartTime
                Task { @MainActor in
                    guard let self, let view = view as? AmbientMetalSurface, duration > 0 else { return }
                    self.onSample?(duration, size)
                    if duration > budget && self.resolutionScale > 0.5 {
                        self.resolutionScale = max(0.5, self.resolutionScale - 0.125)
                        self.cheapSamples = 0
                        view.updateResolution()
                    } else if duration < budget * 0.45 {
                        self.cheapSamples += 1
                        if self.cheapSamples >= 12 && self.resolutionScale < 1 {
                            self.resolutionScale = min(1, self.resolutionScale + 0.125)
                            self.cheapSamples = 0
                            view.updateResolution()
                        }
                    } else { self.cheapSamples = 0 }
                }
            }
        }
        if onPresented != nil {
            drawable.addPresentedHandler { [weak self] shown in
                let time = shown.presentedTime
                Task { @MainActor in self?.onPresented?(time) }
            }
        }
        command.present(drawable)
        command.commit()
    }
}

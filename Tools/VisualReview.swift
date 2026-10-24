// Developer-only harness. Compiled with StillKit sources; never included in Still.app.
import AppKit
import SwiftUI
import MetalKit
import CoreAudio

@main
@MainActor
struct VisualReview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let args = CommandLine.arguments
        if args.contains("--verify-focus-lifecycle") {
            func require(_ condition: Bool, _ message: String) {
                guard condition else { print("FAIL: \(message)"); fflush(nil); exit(1) }
            }
            func outputAudioControls() -> [String: Double] {
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var device = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
                guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return [:] }
                var values = ["device": Double(device)]
                for element: UInt32 in [0, 1, 2] {
                    for (selector, name) in [(kAudioDevicePropertyVolumeScalar, "volume"), (kAudioDevicePropertyMute, "mute")] {
                        address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                        if name == "volume" {
                            var value = Float32(0); size = UInt32(MemoryLayout<Float32>.size)
                            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                                values["\(name)-\(element)"] = Double(value)
                            }
                        } else {
                            var value = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
                            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                                values["\(name)-\(element)"] = Double(value)
                            }
                        }
                    }
                }
                return values
            }
            let audioBefore = outputAudioControls()
            let domain = "app.still.lifecycle.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            let focus = FocusController(defaults: defaults, monitorInbox: false)
            focus.settings.displays = []
            focus.start()
            require(!focus.active && focus.note != nil, "Empty selection must fail safely")
            focus.settings.displays = nil
            guard focus.canStart else { print("SKIP: no display available"); return }
            focus.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let overlays = NSApp.windows.filter { $0.level == .floating && $0.isVisible }
            require(focus.active && !overlays.isEmpty, "Focus windows were not created")
            require(overlays.allSatisfy { !$0.ignoresMouseEvents && !$0.canBecomeMain }, "Focus must receive its exit click")
            require(overlays.allSatisfy { !$0.styleMask.contains(.fullScreen) && $0.level.rawValue < NSWindow.Level.statusBar.rawValue }, "Focus must leave system banners above its windows")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: overlays[0].windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(escape)
            require(!focus.active, "Local Escape must exit Focus")
            require(overlays.allSatisfy { !$0.isVisible && $0.contentView == nil }, "Escape must release windows synchronously")
            focus.start()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let clickWindow = NSApp.windows.first(where: { $0.level == .floating && $0.isVisible }) else {
                throw NSError(domain: "StillFocusValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Focus window for click test"])
            }
            let point = NSPoint(x: clickWindow.frame.width / 2, y: clickWindow.frame.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: clickWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                clickWindow.sendEvent(click)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            require(!focus.active && !clickWindow.isVisible && clickWindow.contentView == nil, "A click must exit Focus and remove the hit target")
            focus.start()
            focus.stop()
            require(!focus.active && overlays.allSatisfy { !$0.isVisible && $0.contentView == nil }, "Focus resources not released")
            focus.start()
            focus.settings.displays = []
            require(!focus.active && focus.note != nil, "Losing selected displays must stop Focus")
            focus.settings.guiAutomation = true
            focus.start()
            require(!focus.active, "GUI automation must prevent covering")
            require(outputAudioControls() == audioBefore, "Focus must not change the default output device, volume or mute")
            print(audioBefore.count > 1 ? "PASS: output device and \(audioBefore.count - 1) supported volume/mute controls unchanged across Focus lifecycle" : "SKIP: device exposes no readable volume/mute controls")
            print("PASS: native Focus entry, local Escape, click exit, synchronous window cleanup, banner-compatible window levels, empty/lost display selection and GUI automation guard; no power controller or user inbox started")
            return
        }
        if args.contains("--verify-ambient") {
            let target = try ReviewTarget(gpu: AmbientGPU.shared.get(), width: 1280, height: 720)
            func pixels(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw NSError(domain: "StillVisualReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            }
            for (theme, light) in AmbientTheme.allCases.flatMap({ theme in [false,true].map { (theme,$0) } }) {
                let (_, first) = try target.draw(theme: theme, time: 0, light: light)
                let (_, later) = try target.draw(theme: theme, time: 3, light: light)
                let a = pixels(first), b = pixels(later)
                let palette = theme.palette(light: light)
                let limits = (0..<3).map { channel in light ? 255 : Int((palette.map { $0[channel] }.max()! * 1.3 * 255).rounded()) + 1 }
                var changed = 0
                for i in stride(from: 0, to: a.count, by: 4) {
                    try check(a[i+3] == 255 && b[i+3] == 255, "Nonopaque backdrop")
                    for channel in 0..<3 {
                        try check(Int(a[i+2-channel]) <= limits[channel] && Int(b[i+2-channel]) <= limits[channel], "Palette gamut exceeded: \(theme)")
                    }
                    if theme == .monochrome {
                        try check(a[i] == a[i+1] && a[i+1] == a[i+2] && b[i] == b[i+1] && b[i+1] == b[i+2], "Monochrome lost neutrality")
                    }
                    if (0..<3).contains(where: { abs(Int(a[i+$0])-Int(b[i+$0])) >= 3 }) { changed += 1 }
                }
                let percentage = Double(changed) / Double(1280*720) * 100
                try check(percentage > 5, "Insufficient visible change after three seconds")
                print("PASS \(theme.rawValue) \(light ? "light" : "dark"): palette bounds, opaque backdrop, neutrality where applicable; \(percentage)% pixels changed by ≥3 levels in 3 seconds")
            }
            for rate in [0.115, 0.079, 0.053, 0.037] {
                let time = Double.pi/rate
                let (_, before) = try target.draw(theme: .aurora, time: time-0.001)
                let (_, after) = try target.draw(theme: .aurora, time: time+0.001)
                let a = pixels(before), b = pixels(after)
                let differences = zip(a,b).map { abs(Int($0)-Int($1)) }
                let mean = Double(differences.reduce(0,+))/Double(differences.count)
                let fraction = Double(differences.filter { $0 > 3 }.count)/Double(differences.count)
                // A moving silhouette can cross a pixel between these timestamps.
                // A loop seam would change a substantial portion of the image.
                try check(mean < 0.1 && fraction < 0.003, "Phase seam at \(time): mean=\(mean), changed fraction=\(fraction)")
                print("PASS phase wrap at \(time)s: mean channel difference=\(mean); fraction over 3 levels=\(fraction)")
            }
            print("10 GPU image checks passed")
            return
        }
        if args.count > 2, args[1] == "--motion-frames" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = try ReviewTarget(gpu: AmbientGPU.shared.get(), width: 1280, height: 720)
            for frame in 0..<240 {
                let (_, image) = try target.draw(theme: .midnight, time: Double(frame)/30)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "%04d.png", frame)))
            }
            print("Rendered 8 seconds of original Metal artwork at 30 fps; no desktop capture")
            return
        }
        if args.count > 2, args[1] == "--ambient-frames" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let gpu = try AmbientGPU.shared.get()
            let target = try ReviewTarget(gpu: gpu, width: 3840, height: 2160)
            for (theme, light) in AmbientTheme.allCases.flatMap({ theme in [false,true].map { (theme,$0) } }) {
                for time in [0.0, 5.0, 18.0] {
                    let (_, image) = try target.draw(theme: theme, time: time, light: light)
                    let name = "\(theme.rawValue)-\(light ? "light" : "dark")-\(Int(time))"
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + "-4k.png"))
                    try render(Image(decorative: image, scale: 1).resizable().overlay {
                        VStack(spacing: 22) {
                            Text("still.").font(.system(size: 154, weight: .light)).tracking(-5)
                            Text("Background work continues").font(.system(size: 12, weight: .medium)).foregroundStyle(light ? Color.black.opacity(0.75) : Color.white.opacity(0.8))
                        }.foregroundStyle(light ? Color(red: 0.1, green: 0.13, blue: 0.23) : Color.white)
                    }.overlay(alignment: .topTrailing) {
                        Text("14:32").font(.system(size: 21, weight: .light)).foregroundStyle(light ? Color.black.opacity(0.7) : Color.white.opacity(0.8)).padding(55)
                    }.frame(width: 1920, height: 1080), to: directory.appendingPathComponent(name + ".png"))
                }
            }
            print("Rendered original Metal artwork at 3840×2160; app-only lockup compositions at 1920×1080: \(directory.path)")
            return
        }
        if args.count > 4, args[1] == "--benchmark" {
            let width = Int(args[2])!, height = Int(args[3])!, count = Int(args[4])!
            let gpu = try AmbientGPU.shared.get()
            let target = try ReviewTarget(gpu: gpu, width: width, height: height)
            var samples: [Double] = []
            let start = CACurrentMediaTime()
            for frame in 0..<(count + 15) {
                let (duration, _) = try target.draw(theme: .midnight, time: Double(frame) / 60, readback: false)
                if frame >= 15 { samples.append(duration * 1000) }
            }
            samples.sort()
            print("GPU: \(gpu.device.name); actual offscreen texture: \(width)×\(height); frames=\(count); warmup=15")
            print("GPU completed-buffer duration ms: mean=\(samples.reduce(0,+)/Double(count)); p50=\(samples[count/2]); p95=\(samples[Int(Double(count)*0.95)]); max=\(samples.last!)")
            print("Wall seconds including serialized submissions/warmup: \(CACurrentMediaTime()-start); this is not display-delivered FPS or system GPU utilization")
            return
        }
        if args.count > 2, args[1] == "--render" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for theme in AmbientTheme.allCases {
                try render(AmbientBackground(theme: theme).overlay {
                    VStack(spacing: 22) {
                        Text("still.").font(.system(size: 130, weight: .light)).tracking(-5)
                        Text("Background work continues").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }.foregroundStyle(.white)
                }.frame(width: 1440, height: 900), to: directory.appendingPathComponent(theme.rawValue + ".png"))
            }
            let defaults = UserDefaults(suiteName: "app.still.visual-review")!
            let focus = FocusController(defaults: defaults, monitorInbox: false)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let scheme: ColorScheme = dark ? .dark : .light
                let suffix = dark ? "dark" : "light"
                try render(FocusSettingsView(focus: focus).padding(22).frame(width: 320)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                    to: directory.appendingPathComponent("focus-settings-\(suffix).png"))
                try render(WelcomeView {}.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme), to: directory.appendingPathComponent("welcome-\(suffix).png"))
                try render(AboutView().environment(\.colorScheme, scheme), to: directory.appendingPathComponent("about-\(suffix).png"))
                NSApp.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                try render(WelcomeView {}.background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                    ,
                    to: directory.appendingPathComponent("welcome-accessible-\(suffix).png"))
                let event = FocusEvent(key: "visual-review", provider: .codex, session: "review", kind: .question, project: "Visual review")
                try render(AttentionCard(event: event, focus: focus).padding(22).frame(width: 344)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
                    ,
                    to: directory.appendingPathComponent("attention-accessible-\(suffix).png"))
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try render(VStack(alignment: .leading, spacing: 24) {
                    HStack { MarkView(style: .active).frame(width: 28, height: 28); Wordmark(size: 19); Spacer() }
                    StatusBlock(summary: StatusSummary.make(decision: SessionDecision(phase: .inactive, holdAwake: false, autoArmed: false, inGrace: false), restoring: false, streamName: nil, streamActive: false, agent: nil, batteryFloor: 15, now: Date()))
                    StatusBlock(summary: StatusSummary.make(decision: SessionDecision(phase: .suspended(.thermal), holdAwake: false, autoArmed: false, inGrace: false), restoring: false, streamName: nil, streamActive: false, agent: nil, batteryFloor: 15, now: Date()))
                    AttentionCard(event: event, focus: focus)
                }.padding(22).frame(width: 320).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme), to: directory.appendingPathComponent("states-\(suffix).png"))
            }
            print("Rendered native components to \(directory.path)")
            return
        }
        // Finite animation workload, with no inbox, power controller or application preferences.
        let fps = args.count > 2 ? Double(args[2]) ?? 60 : 60
        let width = args.count > 3 ? Double(args[3]) ?? 1920 : 1920
        let height = args.count > 4 ? Double(args[4]) ?? 1080 : 1080
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Still · Ambient profiling"
        window.contentView = NSHostingView(rootView: AmbientBackground(theme: .midnight, framesPerSecond: fps))
        window.center(); window.makeKeyAndOrderFront(nil)
        let telemetry = ReviewTelemetry()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                let size = window.contentView?.bounds.size ?? .zero
                print("Ambient workload: requested=\(width)x\(height) points; actual=\(size); backingScale=\(window.backingScaleFactor); targetFPS=\(fps)")
                if let surface = findSurface(window.contentView), let renderer = surface.renderer {
                    telemetry.surface = surface
                    renderer.onSample = { duration, size in telemetry.gpu.append(duration*1000); telemetry.size = size }
                    renderer.onPresented = { time in if time > 0 { telemetry.presented.append(time) } }
                    print("Metal surface: frame=\(surface.frame); bounds=\(surface.bounds); backingScale=\(window.backingScaleFactor); drawable=\(surface.drawableSize); displayMaximumFPS=\(window.screen?.maximumFramesPerSecond ?? 0); paused=\(surface.isPaused)")
                    fflush(nil)
                    precondition(surface.drawableSize.width > 100, "Metal drawable failed to follow SwiftUI layout")
                } else { print("ERROR: Metal surface missing") }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 28, repeats: false) { _ in
            MainActor.assumeIsolated {
                telemetry.report()
                window.orderOut(nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 29, repeats: false) { _ in
            MainActor.assumeIsolated { telemetry.hiddenFrames = telemetry.surface?.renderer?.submittedFrames ?? -1 }
        }
        Timer.scheduledTimer(withTimeInterval: 31, repeats: false) { _ in
            MainActor.assumeIsolated {
                let count = telemetry.surface?.renderer?.submittedFrames ?? -2
                print("Hidden submission delta after drain: \(count - telemetry.hiddenFrames); paused=\(telemetry.surface?.isPaused ?? false)")
                window.makeKeyAndOrderFront(nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 33, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let surface = telemetry.surface else { return }
                print("Resumed: paused=\(surface.isPaused); submissions=\(surface.renderer?.submittedFrames ?? -1)")
                surface.configure(theme: .midnight, fps: 0)
                telemetry.staticFrames = surface.renderer?.submittedFrames ?? -1
            }
        }
        Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { _ in
            MainActor.assumeIsolated {
                print("Static submission delta (includes final invalidation): \((telemetry.surface?.renderer?.submittedFrames ?? -2) - telemetry.staticFrames); paused=\(telemetry.surface?.isPaused ?? false)")
                window.contentView = nil; window.orderOut(nil); app.terminate(nil)
            }
        }
        app.run()
    }
    static func findSurface(_ view: NSView?) -> AmbientMetalSurface? {
        if let surface = view as? AmbientMetalSurface { return surface }
        for child in view?.subviews ?? [] { if let surface = findSurface(child) { return surface } }
        return nil
    }
    static func render<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSApp.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class ReviewTelemetry {
    weak var surface: AmbientMetalSurface?
    var gpu: [Double] = []
    var presented: [Double] = []
    var size = CGSize.zero
    var hiddenFrames = 0
    var staticFrames = 0
    func report() {
        let sorted = gpu.sorted()
        if !sorted.isEmpty {
            print("Onscreen GPU ms: count=\(sorted.count); mean=\(sorted.reduce(0,+)/Double(sorted.count)); p95=\(sorted[Int(Double(sorted.count)*0.95)]); finalDrawable=\(size)")
        }
        if let first = presented.first, let last = presented.last, last > first {
            let intervals = zip(presented.dropFirst(), presented).map { ($0-$1)*1000 }.sorted()
            print("Drawable presentation callbacks: count=\(presented.count); cadence=\(Double(presented.count-1)/(last-first)) fps; intervalP95=\(intervals[Int(Double(intervals.count)*0.95)]) ms")
        } else { print("No positive presentation timestamps (static or unavailable)") }
        print("Submissions: \(surface?.renderer?.submittedFrames ?? -1)")
    }
}

/// Direct readback of this app's render target; never captures desktop pixels.
@MainActor
private final class ReviewTarget {
    let gpu: AmbientGPU
    let queue: MTLCommandQueue
    let texture: MTLTexture
    let pass: MTLRenderPassDescriptor
    let width: Int
    let height: Int
    init(gpu: AmbientGPU, width: Int, height: Int) throws {
        self.gpu = gpu; self.width = width; self.height = height
        guard let queue = gpu.device.makeCommandQueue() else { throw AmbientError.unavailable }
        self.queue = queue
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: AmbientGPU.format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { throw AmbientError.unavailable }
        self.texture = texture
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depth = gpu.device.makeTexture(descriptor: depthDescriptor) else { throw AmbientError.unavailable }
        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

    }
    func draw(theme: AmbientTheme, time: Double, light: Bool = false, readback: Bool = true) throws -> (Double, CGImage) {
        guard let command = queue.makeCommandBuffer() else { throw AmbientError.unavailable }
        gpu.encode(command: command, pass: pass, size: CGSize(width: width, height: height), seconds: time, palette: theme.palette(light: light), light: light)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let duration = command.gpuEndTime-command.gpuStartTime
        // A 1×1 placeholder avoids full-size CPU readback in the GPU benchmark.
        let w = readback ? width : 1, h = readback ? height : 1
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        texture.getBytes(&bytes, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return (duration, image)
    }
}

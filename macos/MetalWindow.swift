import AppKit
import Metal
import QuartzCore
import CoreVideo

/// Simple Metal view that wraps a CAMetalLayer
class MetalView: NSView {
    var metalLayer: CAMetalLayer!

    // Mouse tracking
    var mouseX: Float = 0.0
    var mouseY: Float = 0.0
    var mouseDown: Bool = false

    // CRITICAL: Tell AppKit this view is fully opaque (no transparency)
    override var isOpaque: Bool { return true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetalLayer()
    }

    private func setupMetalLayer() {
        // Create the Metal layer
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm  // Native blending (Ghostty default)
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true  // CRITICAL: Tell CA this layer is fully opaque

        // Set Display P3 colorspace (like Ghostty) for Apple-style rendering
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        // Make the layer update when bounds change
        self.wantsLayer = true
        self.layer = metalLayer

        // CRITICAL: Tell the view itself it's opaque (no transparency)
        self.layer?.isOpaque = true

        // Set initial drawable size (will be updated in setFrameSize)
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        print("[View] setupMetalLayer: bounds=\(bounds.width)x\(bounds.height), scale=\(scale), drawable=\(metalLayer.drawableSize.width)x\(metalLayer.drawableSize.height)")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Update the Metal layer drawable size to match the view
        // Use screen scale if window not available yet
        let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(
            width: newSize.width * scale,
            height: newSize.height * scale
        )
        print("[View] setFrameSize: \(newSize.width)x\(newSize.height), scale=\(scale), drawable=\(metalLayer.drawableSize.width)x\(metalLayer.drawableSize.height)")
    }

    // Mouse event handling
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)  // Flip Y (top-left origin)
        mouseDown = true
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
        mouseDown = false
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
    }
}

/// C-compatible callbacks for Zig
@_cdecl("metal_window_create")
public
func metal_window_create(width: Int32, height: Int32, borderless: Bool) -> UnsafeMutableRawPointer? {
    let window = MetalWindow(
        width: CGFloat(width),
        height: CGFloat(height),
        borderless: borderless
    )

    // Return an unmanaged pointer that Zig can hold onto
    return Unmanaged.passRetained(window).toOpaque()
}

@_cdecl("metal_window_get_layer")
public func metal_window_get_layer(_ windowPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    guard let metalView = window.contentView as? MetalView else { return nil }

    // Return the CAMetalLayer pointer
    return Unmanaged.passRetained(metalView.metalLayer).toOpaque()
}

@_cdecl("metal_window_get_device")
public func metal_window_get_device(_ windowPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    guard let metalView = window.contentView as? MetalView else { return nil }
    guard let device = metalView.metalLayer.device else { return nil }

    // Return the MTLDevice pointer
    return Unmanaged.passRetained(device).toOpaque()
}

@_cdecl("metal_window_show")
public func metal_window_show(_ windowPtr: UnsafeMutableRawPointer) {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    window.makeKeyAndOrderFront(nil)
}

@_cdecl("metal_window_init_app")
public func metal_window_init_app() {
    // Initialize NSApplication without running the main loop
    let _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
}

@_cdecl("metal_window_run_app")
public func metal_window_run_app() {
    // Initialize NSApplication if needed
    let _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.run()
}

@_cdecl("metal_window_is_running")
public func metal_window_is_running(_ windowPtr: UnsafeMutableRawPointer) -> Bool {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    return window.isVisible && NSApplication.shared.isRunning
}

@_cdecl("metal_layer_get_next_drawable")
public func metal_layer_get_next_drawable(_ layerPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let layer = Unmanaged<CAMetalLayer>.fromOpaque(layerPtr).takeUnretainedValue()
    guard let drawable = layer.nextDrawable() else { return nil }
    
    // Return the CAMetalDrawable pointer
    return Unmanaged.passRetained(drawable).toOpaque()
}

@_cdecl("metal_drawable_get_texture")
public func metal_drawable_get_texture(_ drawablePtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let drawable = Unmanaged<CAMetalDrawable>.fromOpaque(drawablePtr).takeUnretainedValue()
    
    // Return the MTLTexture pointer
    return Unmanaged.passRetained(drawable.texture).toOpaque()
}

@_cdecl("metal_drawable_present")
public func metal_drawable_present(_ drawablePtr: UnsafeMutableRawPointer) {
    let drawable = Unmanaged<CAMetalDrawable>.fromOpaque(drawablePtr).takeUnretainedValue()
    drawable.present()
}

@_cdecl("metal_window_process_events")
public func metal_window_process_events(_ windowPtr: UnsafeMutableRawPointer) {
    // Process ALL pending events (drain the queue)
    while true {
        let event = NSApplication.shared.nextEvent(
            matching: .any,
            until: nil,  // Don't wait, return immediately if no events
            inMode: .default,
            dequeue: true
        )

        guard let event = event else {
            break  // No more events, exit loop
        }

        NSApplication.shared.sendEvent(event)
    }
}

@_cdecl("metal_window_release")
public func metal_window_release(_ windowPtr: UnsafeMutableRawPointer) {
    let _ = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeRetainedValue()
    // Window is now released
}

@_cdecl("metal_window_get_mouse_state")
public func metal_window_get_mouse_state(
    _ windowPtr: UnsafeMutableRawPointer,
    _ outX: UnsafeMutablePointer<Float>,
    _ outY: UnsafeMutablePointer<Float>,
    _ outDown: UnsafeMutablePointer<Bool>
) {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    guard let metalView = window.contentView as? MetalView else {
        outX.pointee = 0
        outY.pointee = 0
        outDown.pointee = false
        return
    }

    outX.pointee = metalView.mouseX
    outY.pointee = metalView.mouseY
    outDown.pointee = metalView.mouseDown
}

@_cdecl("metal_layer_set_pixel_format")
public func metal_layer_set_pixel_format(_ layerPtr: UnsafeMutableRawPointer, _ pixelFormat: UInt) {
    let layer = Unmanaged<CAMetalLayer>.fromOpaque(layerPtr).takeUnretainedValue()
    layer.pixelFormat = MTLPixelFormat(rawValue: pixelFormat) ?? .bgra8Unorm
}

@_cdecl("metal_window_get_backing_scale")
public func metal_window_get_backing_scale(_ windowPtr: UnsafeMutableRawPointer) -> Double {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    return window.backingScaleFactor
}

// MARK: - CVDisplayLink

/// Wrapper class to hold CVDisplayLink and callback
class MetalDisplayLinkWrapper {
    var displayLink: CVDisplayLink?
    var callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    var userdata: UnsafeMutableRawPointer?
}

// CVDisplayLink callback function (C function, not a method)
private func displayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ displayLinkContext: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context = displayLinkContext else { return kCVReturnSuccess }

    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(context).takeUnretainedValue()
    wrapper.callback?(wrapper.userdata)

    return kCVReturnSuccess
}

@_cdecl("metal_displaylink_create")
public func metal_displaylink_create(_ windowPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let wrapper = MetalDisplayLinkWrapper()

    // Create CVDisplayLink
    var displayLink: CVDisplayLink?
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

    if result != kCVReturnSuccess || displayLink == nil {
        return nil
    }

    wrapper.displayLink = displayLink
    return Unmanaged.passRetained(wrapper).toOpaque()
}

@_cdecl("metal_displaylink_set_callback")
public func metal_displaylink_set_callback(
    _ wrapperPtr: UnsafeMutableRawPointer,
    _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ userdata: UnsafeMutableRawPointer?
) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()
    wrapper.callback = callback
    wrapper.userdata = userdata

    // Set the callback on the CVDisplayLink
    if let displayLink = wrapper.displayLink {
        CVDisplayLinkSetOutputCallback(displayLink, displayLinkCallback, wrapperPtr)
    }
}

@_cdecl("metal_displaylink_start")
public func metal_displaylink_start(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStart(displayLink)
    }
}

@_cdecl("metal_displaylink_stop")
public func metal_displaylink_stop(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStop(displayLink)
    }
}

@_cdecl("metal_displaylink_release")
public func metal_displaylink_release(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeRetainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStop(displayLink)
    }
}

/// Minimal Metal window wrapper
class MetalWindow: NSWindow {
    init(width: CGFloat, height: CGFloat, borderless: Bool) {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)

        // Choose window style
        let styleMask: NSWindow.StyleMask = borderless
            ? [.borderless]
            : [.titled, .closable, .resizable, .miniaturizable]

        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        // Set up the window
        self.title = "Metal IMGUI"
        self.isOpaque = true
        self.backgroundColor = .black

        // Enable mouse tracking
        self.acceptsMouseMovedEvents = true

        // Center the window on screen
        self.center()

        // Create and set the Metal view
        let metalView = MetalView(frame: contentRect)
        self.contentView = metalView

        // Debug: print actual window size
        print("[Window] Requested: \(width)x\(height), Actual: \(frame.width)x\(frame.height), ContentView: \(metalView.frame.width)x\(metalView.frame.height)")

        // For borderless windows, allow moving by dragging
        if borderless {
            self.isMovableByWindowBackground = true
        }
    }
}

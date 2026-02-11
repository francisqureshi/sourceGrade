import AppKit
import CoreVideo
import Metal
import QuartzCore

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

    /// Configure the CAMetalLayer with device, pixel format, colorspace, and drawable size.
    private func setupMetalLayer() {
        // Create the Metal layer
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm  // Native blending (Ghostty default)
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true  // CRITICAL: Tell CA this layer is fully opaque

        // Set Display P3 colorspace (like Ghostty) for Apple-style rendering
        // metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        // Trying sRGB for Decoder...
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

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
    }

    /// Update the Metal layer drawable size when the view resizes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Update the Metal layer drawable size to match the view
        // Use screen scale if window not available yet
        let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(
            width: newSize.width * scale,
            height: newSize.height * scale
        )
    }

    /// Handle mouse button press - update position and set mouseDown flag.
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)  // Flip Y (top-left origin)
        mouseDown = true
    }

    /// Handle mouse button release - update position and clear mouseDown flag.
    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
        mouseDown = false
    }

    /// Handle mouse movement - update position.
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
    }

    /// Handle mouse drag - update position while button is held.
    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseX = Float(location.x)
        mouseY = Float(bounds.height - location.y)
    }

    /// Rebuild tracking areas when view resizes to ensure mouse events are captured.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas (resize)
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        // Add new tracking area covering entire view
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}

// MARK: - Window Management

/// Create a new Metal window with the specified dimensions.
/// Returns an opaque pointer for Zig to hold onto.
@_cdecl("metal_window_create")
public func metal_window_create(width: Int32, height: Int32, borderless: Bool)
    -> UnsafeMutableRawPointer?
{
    let window = MetalWindow(
        width: CGFloat(width),
        height: CGFloat(height),
        borderless: borderless
    )

    // Return an unmanaged pointer that Zig can hold onto
    return Unmanaged.passRetained(window).toOpaque()
}

/// Get the CAMetalLayer from a window for rendering.
/// Returns nil if the window doesn't have a MetalView.
@_cdecl("metal_window_get_layer")
public func metal_window_get_layer(_ windowPtr: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
{
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    guard let metalView = window.contentView as? MetalView else { return nil }

    // Return the CAMetalLayer pointer
    return Unmanaged.passRetained(metalView.metalLayer).toOpaque()
}

/// Get the MTLDevice from a window's Metal layer.
/// Returns nil if device is not available.
@_cdecl("metal_window_get_device")
public func metal_window_get_device(_ windowPtr: UnsafeMutableRawPointer)
    -> UnsafeMutableRawPointer?
{
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    guard let metalView = window.contentView as? MetalView else { return nil }
    guard let device = metalView.metalLayer.device else { return nil }

    // Return the MTLDevice pointer
    return Unmanaged.passRetained(device).toOpaque()
}

/// Make the window visible and bring it to front.
@_cdecl("metal_window_show")
public func metal_window_show(_ windowPtr: UnsafeMutableRawPointer) {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    window.makeKeyAndOrderFront(nil)
}

/// Initialize NSApplication with menu bar and activation policy.
/// Call before showing windows or running the event loop.
@_cdecl("metal_window_init_app")
public func metal_window_init_app() {
    // Initialize NSApplication without running the main loop
    let _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)

    // Create main menu with Quit item (Cmd+Q)
    let mainMenu = NSMenu()

    // Application menu (first menu, uses app name)
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu

    // Quit menu item
    let quitItem = NSMenuItem(
        title: "Quit",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenu.addItem(quitItem)

    NSApplication.shared.mainMenu = mainMenu
}

/// Run the NSApplication event loop (blocks forever).
/// This is the main run loop for macOS apps.
@_cdecl("metal_window_run_app")
public func metal_window_run_app() {
    // Initialize NSApplication if needed
    let _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.run()
}

/// Check if the window is still visible and the app is running.
@_cdecl("metal_window_is_running")
public func metal_window_is_running(_ windowPtr: UnsafeMutableRawPointer) -> Bool {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    return window.isVisible && NSApplication.shared.isRunning
}

/// Process all pending events without blocking.
/// Drains the event queue and dispatches events to handlers.
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

/// Release a window, balancing the retain from metal_window_create.
@_cdecl("metal_window_release")
public func metal_window_release(_ windowPtr: UnsafeMutableRawPointer) {
    let _ = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeRetainedValue()
    // Window is now released
}

/// Get current mouse position and button state from a window's MetalView.
/// Coordinates are in points with top-left origin.
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

/// Get the window's backing scale factor for HiDPI (Retina) support.
/// Returns 2.0 on Retina displays, 1.0 on standard displays.
@_cdecl("metal_window_get_backing_scale")
public func metal_window_get_backing_scale(_ windowPtr: UnsafeMutableRawPointer) -> Double {
    let window = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeUnretainedValue()
    return window.backingScaleFactor
}

// MARK: - Metal Layer / Drawable

/// Get the next drawable from a CAMetalLayer for rendering.
/// Returns nil if no drawable is available (e.g., window minimized).
@_cdecl("metal_layer_get_next_drawable")
public func metal_layer_get_next_drawable(_ layerPtr: UnsafeMutableRawPointer)
    -> UnsafeMutableRawPointer?
{
    let layer = Unmanaged<CAMetalLayer>.fromOpaque(layerPtr).takeUnretainedValue()
    guard let drawable = layer.nextDrawable() else { return nil }

    // Return the CAMetalDrawable pointer
    return Unmanaged.passRetained(drawable).toOpaque()
}

/// Set the pixel format on a CAMetalLayer.
/// Common formats: bgra8Unorm (70), rgb10a2Unorm (90).
@_cdecl("metal_layer_set_pixel_format")
public func metal_layer_set_pixel_format(_ layerPtr: UnsafeMutableRawPointer, _ pixelFormat: UInt) {
    let layer = Unmanaged<CAMetalLayer>.fromOpaque(layerPtr).takeUnretainedValue()
    layer.pixelFormat = MTLPixelFormat(rawValue: pixelFormat) ?? .bgra8Unorm
}

/// Get the MTLTexture from a drawable for rendering.
@_cdecl("metal_drawable_get_texture")
public func metal_drawable_get_texture(_ drawablePtr: UnsafeMutableRawPointer)
    -> UnsafeMutableRawPointer?
{
    let drawable = Unmanaged<CAMetalDrawable>.fromOpaque(drawablePtr).takeUnretainedValue()

    // Return the MTLTexture pointer
    return Unmanaged.passRetained(drawable.texture).toOpaque()
}

/// Present a drawable to the screen.
/// Call after rendering is complete.
@_cdecl("metal_drawable_present")
public func metal_drawable_present(_ drawablePtr: UnsafeMutableRawPointer) {
    let drawable = Unmanaged<CAMetalDrawable>.fromOpaque(drawablePtr).takeUnretainedValue()
    drawable.present()
}

/// Release a drawable, balancing the retain from metal_layer_get_next_drawable.
@_cdecl("metal_drawable_release")
public func metal_drawable_release(_ drawablePtr: UnsafeMutableRawPointer) {
    // Balance the passRetained from metal_layer_get_next_drawable
    let _ = Unmanaged<CAMetalDrawable>.fromOpaque(drawablePtr).takeRetainedValue()
}

/// Release a texture, balancing the retain from metal_drawable_get_texture.
@_cdecl("metal_texture_release")
public func metal_texture_release(_ texturePtr: UnsafeMutableRawPointer) {
    // Balance the passRetained from metal_drawable_get_texture
    let _ = Unmanaged<AnyObject>.fromOpaque(texturePtr).takeRetainedValue()
}

// MARK: - CVDisplayLink

/// Wrapper class to hold CVDisplayLink and callback state.
/// Manages vsync timing and frame dispatch.
class MetalDisplayLinkWrapper: NSObject {
    var displayLink: CVDisplayLink?
    var callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    var userdata: UnsafeMutableRawPointer?
    var dispatchToMain: Bool = false

    // Track if a frame is already pending to avoid queue buildup
    var framePending: Bool = false

    @objc func performRenderCallback() {
        callback?(userdata)
    }
}

/// CVDisplayLink callback - fires on vsync from display thread.
/// Either dispatches to main thread or calls directly based on dispatchToMain flag.
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

    if wrapper.dispatchToMain {
        // Skip if previous frame still pending (frame dropping)
        if wrapper.framePending {
            return kCVReturnSuccess
        }
        wrapper.framePending = true

        // Dispatch to main via GCD
        DispatchQueue.main.async { [weak wrapper, callback = wrapper.callback, userdata = wrapper.userdata] in
            callback?(userdata)
            wrapper?.framePending = false
        }
    } else {
        // Legacy path: call directly on display link thread
        wrapper.callback?(wrapper.userdata)
    }

    return kCVReturnSuccess
}

/// Create a CVDisplayLink for vsync-synchronized rendering.
/// Returns an opaque wrapper pointer.
@_cdecl("metal_displaylink_create")
public func metal_displaylink_create(_ windowPtr: UnsafeMutableRawPointer)
    -> UnsafeMutableRawPointer?
{
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

/// Set the callback function and userdata for CVDisplayLink vsync events.
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

/// Start the CVDisplayLink - begins firing vsync callbacks.
@_cdecl("metal_displaylink_start")
public func metal_displaylink_start(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStart(displayLink)
    }
}

/// Stop the CVDisplayLink - pauses vsync callbacks.
@_cdecl("metal_displaylink_stop")
public func metal_displaylink_stop(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStop(displayLink)
    }
}

/// Enable/disable dispatching callbacks to main thread.
/// When enabled, callbacks run on main thread via GCD with frame dropping.
/// When disabled, callbacks run directly on CVDisplayLink thread (legacy).
@_cdecl("metal_displaylink_set_dispatch_to_main")
public func metal_displaylink_set_dispatch_to_main(_ wrapperPtr: UnsafeMutableRawPointer, _ enabled: Bool) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeUnretainedValue()
    wrapper.dispatchToMain = enabled
}

/// Release a CVDisplayLink wrapper, stopping it first if running.
@_cdecl("metal_displaylink_release")
public func metal_displaylink_release(_ wrapperPtr: UnsafeMutableRawPointer) {
    let wrapper = Unmanaged<MetalDisplayLinkWrapper>.fromOpaque(wrapperPtr).takeRetainedValue()

    if let displayLink = wrapper.displayLink {
        CVDisplayLinkStop(displayLink)
    }
}

// MARK: - MetalWindow Class

/// Minimal Metal window wrapper with NSWindow subclass.
/// Creates window with MetalView as content view.
class MetalWindow: NSWindow {
    init(width: CGFloat, height: CGFloat, borderless: Bool) {
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)

        // Choose window style
        let styleMask: NSWindow.StyleMask =
            borderless
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

        // For borderless windows, allow moving by dragging
        if borderless {
            self.isMovableByWindowBackground = true
        }
    }
}

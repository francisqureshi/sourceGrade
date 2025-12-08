import AppKit
import Metal
import QuartzCore

/// Simple Metal view that wraps a CAMetalLayer
class MetalView: NSView {
    var metalLayer: CAMetalLayer!

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
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false

        // Make the layer update when bounds change
        self.wantsLayer = true
        self.layer = metalLayer
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Update the Metal layer drawable size to match the view
        let scale = self.window?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(
            width: newSize.width * scale,
            height: newSize.height * scale
        )
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
    // Process pending events
    let event = NSApplication.shared.nextEvent(
        matching: .any,
        until: nil,
        inMode: .default,
        dequeue: true
    )
    if event != nil {
        NSApplication.shared.sendEvent(event!)
    }
}

@_cdecl("metal_window_release")
public func metal_window_release(_ windowPtr: UnsafeMutableRawPointer) {
    let _ = Unmanaged<MetalWindow>.fromOpaque(windowPtr).takeRetainedValue()
    // Window is now released
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
        self.title = "Metal Triangle"
        self.isOpaque = true
        self.backgroundColor = .black

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

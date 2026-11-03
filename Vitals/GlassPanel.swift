import AppKit
import SwiftUI

/// A borderless, rounded panel with the same backdrop as the menu-bar panel:
/// Liquid Glass on macOS 26+, popover material before. No title bar, no window buttons.
final class GlassPanel: NSPanel {
    private let host: NSView

    init<Content: View>(rootView: Content) {
        let hosting = NSHostingView(rootView: rootView)
        host = hosting
        let backdrop = Self.backdrop(size: hosting.fittingSize)
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.contentView = hosting
        } else {
            backdrop.addSubview(hosting)
        }
        super.init(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        contentView = backdrop
    }

    // Borderless panels can't become key by default; controls need key state to render as active.
    override var canBecomeKey: Bool { true }

    /// Shows the panel with its top-right corner just under the menu bar, where the
    /// status item's own panel appears, after the content has measured itself.
    func showUnderMenuBar() {
        func place() {
            setContentSize(host.fittingSize)
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 12, y: visible.maxY - 6))
            }
            display()
            invalidateShadow()   // retrace the shadow from the rounded shape, not the square frame
        }
        place()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { place() }
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }   // Esc closes

    private static func backdrop(size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 26
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        return blur
    }
}

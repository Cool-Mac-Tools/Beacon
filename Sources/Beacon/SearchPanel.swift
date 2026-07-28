import AppKit

/// A borderless, floating panel that hosts the SwiftUI search UI.
/// It can become the key window (so the search field receives keystrokes)
/// while still behaving like a lightweight launcher overlay.
final class SearchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Drag any empty chrome (top strip, side margins, footer gaps) to move
        // the panel. Result rows override mouseDownCanMoveWindow to false and
        // handle their own drag (see ResultInteractionView), so a drag beginning
        // on a row still drags that *item* out of Beacon rather than the window.
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Stay available across spaces and over full-screen apps.
        // NOTE: .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive;
        // setting both raises an exception. Use canJoinAllSpaces only.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Don't keep the app alive / show in the window menu.
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    // Borderless/utility panels don't become key by default; allow it so the
    // embedded text field can accept input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Position the panel horizontally centered and in the upper third of the
    /// screen that currently contains the mouse (matches Spotlight behavior).
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - (visible.height * 0.18)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

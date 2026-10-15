import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above other apps without stealing focus.
final class FloatingPanel: NSPanel {
    var allowsKey = false

    init(level: NSWindow.Level = .popUpMenu) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosts SwiftUI in a FloatingPanel and keeps it sized to its content.
@MainActor
final class HostedPanel<Content: View> {
    let panel: FloatingPanel
    let hosting: NSHostingView<Content>

    init(rootView: Content, level: NSWindow.Level = .popUpMenu, allowsKey: Bool = false) {
        panel = FloatingPanel(level: level)
        panel.allowsKey = allowsKey
        hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = hosting
    }

    var fittingSize: CGSize {
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    var isVisible: Bool { panel.isVisible }

    /// Places the panel next to `anchor` (global points): above it when there's room, else below.
    func place(near anchor: CGRect, gap: CGFloat = 8, preferAbove: Bool = true) {
        let size = fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = Demo.region ?? screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height
        var y: CGFloat
        if preferAbove {
            y = above + size.height <= visible.maxY - 4 ? above : below
        } else {
            y = below >= visible.minY + 4 ? below : above
        }
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.setFrame(CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    func show() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            if panel.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            // Skip if show() was called again during the fade.
            Task { @MainActor in if panel.alphaValue < 0.05 { panel.orderOut(nil) } }
        })
    }
}

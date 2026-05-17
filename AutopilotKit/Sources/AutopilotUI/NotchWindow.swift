import AppKit
import SwiftUI

/// A borderless, transparent panel anchored to the top-center of the screen.
///
/// It is a non-activating panel so it never steals frontmost status from the
/// app the agent is operating, yet it can still become key to accept text in
/// the prompt field.
public final class NotchWindow: NSPanel {
    public init(rootView: some View) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Allow the borderless panel to become key so the prompt field works.
    public override var canBecomeKey: Bool { true }

    /// Move/resize the panel to `frame`, optionally animated.
    public func setFrame(_ frame: CGRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }
}

import AppKit
import AutopilotCore
import SwiftUI

/// Draws a transient, non-interactive highlight over the target app before an
/// action fires.
@MainActor
final class ActionHighlightController {
    private var window: NSPanel?

    func show(_ target: ActionTarget?) {
        guard let frame = target?.frame?.highlightCGRect, frame.width > 1, frame.height > 1 else {
            hide()
            return
        }

        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(frame.insetBy(dx: -4, dy: -4), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ActionHighlightView())
        return window
    }
}

private struct ActionHighlightView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .stroke(.yellow, lineWidth: 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.yellow.opacity(0.12))
            )
            .allowsHitTesting(false)
    }
}

private extension ElementFrame {
    var highlightCGRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

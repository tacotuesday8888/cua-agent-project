import AppKit
import SwiftUI

/// Owns the notch panel lifecycle and keeps it aligned to the active screen.
///
/// The controller deliberately knows only about window placement and the shared
/// model. Final notch visuals can replace `NotchAssistantView` without changing
/// app launch, session state, or safety approval wiring.
@MainActor
public final class NotchController {
    private let model: AgentViewModel
    private var window: NotchWindow?
    private var screenObserver: NSObjectProtocol?

    public init(model: AgentViewModel = AgentViewModel()) {
        self.model = model
    }

    /// Create and show the collapsed notch panel.
    public func start() {
        guard window == nil else {
            show(expanded: model.isExpanded)
            return
        }

        model.refreshApps()
        let rootView = NotchAssistantView(model: model) { [weak self] expanded in
            self?.applyLayout(expanded: expanded, animated: true)
        }
        let window = NotchWindow(rootView: rootView)
        self.window = window

        applyLayout(expanded: model.isExpanded, animated: false)
        window.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyLayout(expanded: self.model.isExpanded, animated: false)
            }
        }
    }

    /// Show the panel, optionally expanded for direct input.
    public func show(expanded: Bool = true) {
        if window == nil {
            start()
        }

        model.isExpanded = expanded
        applyLayout(expanded: expanded, animated: true)
        window?.orderFrontRegardless()
        if expanded {
            window?.makeKey()
        }
    }

    private func applyLayout(expanded: Bool, animated: Bool) {
        let geometry = NotchGeometry()
        let frame = expanded
            ? geometry.expandedFrame(
                width: NotchAssistantView.expandedWidth,
                height: NotchAssistantView.expandedHeight
            )
            : geometry.collapsedFrame
        window?.setFrame(frame, animated: animated)
    }
}

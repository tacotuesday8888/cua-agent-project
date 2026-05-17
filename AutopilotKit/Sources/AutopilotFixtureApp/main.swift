import AppKit

@MainActor
final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let inputField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let logView = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Autopilot Fixture"
        window.center()
        window.setAccessibilityIdentifier("autopilot.fixture.window")

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Autopilot Fixture")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.setAccessibilityIdentifier("autopilot.fixture.title")

        inputField.placeholderString = "Smoke input"
        inputField.setAccessibilityIdentifier("autopilot.fixture.input")
        inputField.setAccessibilityLabel("Smoke input")

        let runButton = NSButton(title: "Run", target: self, action: #selector(runClicked))
        runButton.bezelStyle = .rounded
        runButton.setAccessibilityIdentifier("autopilot.fixture.run-button")
        runButton.setAccessibilityLabel("Run")

        statusLabel.setAccessibilityIdentifier("autopilot.fixture.status")
        statusLabel.setAccessibilityLabel("Status")

        logView.string = (1...24).map { "Fixture log line \($0)" }.joined(separator: "\n")
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.setAccessibilityIdentifier("autopilot.fixture.log")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = logView
        scrollView.borderType = .bezelBorder
        scrollView.setAccessibilityIdentifier("autopilot.fixture.scroll")

        let dragRow = NSStackView()
        dragRow.orientation = .horizontal
        dragRow.spacing = 12
        dragRow.alignment = .centerY

        let dragSource = NSBox()
        dragSource.title = "Drag source"
        dragSource.boxType = .primary
        dragSource.setAccessibilityIdentifier("autopilot.fixture.drag-source")
        dragSource.setAccessibilityLabel("Drag source")

        let dropTarget = NSBox()
        dropTarget.title = "Drop target"
        dropTarget.boxType = .primary
        dropTarget.setAccessibilityIdentifier("autopilot.fixture.drop-target")
        dropTarget.setAccessibilityLabel("Drop target")

        dragRow.addArrangedSubview(dragSource)
        dragRow.addArrangedSubview(dropTarget)

        root.addArrangedSubview(title)
        root.addArrangedSubview(inputField)
        root.addArrangedSubview(runButton)
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(dragRow)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),

            inputField.widthAnchor.constraint(equalToConstant: 360),
            scrollView.widthAnchor.constraint(equalToConstant: 460),
            scrollView.heightAnchor.constraint(equalToConstant: 170),
            dragSource.widthAnchor.constraint(equalToConstant: 150),
            dragSource.heightAnchor.constraint(equalToConstant: 68),
            dropTarget.widthAnchor.constraint(equalToConstant: 150),
            dropTarget.heightAnchor.constraint(equalToConstant: 68)
        ])

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc private func runClicked() {
        statusLabel.stringValue = "Run clicked: \(inputField.stringValue)"
    }
}

let app = NSApplication.shared
let delegate = FixtureAppDelegate()
app.delegate = delegate
app.run()

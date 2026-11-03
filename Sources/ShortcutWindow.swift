import AppKit

/// Small window for recording a new global shortcut.
final class ShortcutWindowController: NSWindowController, NSWindowDelegate {
    var current: Shortcut
    /// Called when the user records a new shortcut.
    var onChange: ((Shortcut) -> Void)?
    /// Called when recording starts/stops, so the global hotkey can be paused meanwhile.
    var onRecordingChanged: ((Bool) -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "")
    private var monitor: Any?

    init(current: Shortcut) {
        self.current = current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Skratka Diktafónu"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Skratka na zapnutie a vypnutie diktovania:")
        title.font = .systemFont(ofSize: 13)

        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        button.target = self
        button.action = #selector(toggleRecording)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, button, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window!.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window!.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window!.contentView!.centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        refresh(recording: false)
    }

    private func refresh(recording: Bool) {
        button.title = recording ? "Stlač skratku…" : current.displayString
        hint.stringValue = recording
            ? "Použi aspoň jeden z ⌃ ⌥ ⌘ (alebo F-kláves). Esc zruší."
            : "Klikni na tlačidlo a stlač novú kombináciu."
    }

    @objc private func toggleRecording() {
        monitor == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        onRecordingChanged?(true)
        refresh(recording: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.stopRecording()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                self.current = shortcut
                self.onChange?(shortcut)
                self.stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh(recording: false)
        onRecordingChanged?(false)
    }

    func show() {
        refresh(recording: monitor != nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if monitor != nil { stopRecording() }
    }
}

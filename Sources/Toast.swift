import AppKit

/// Non-blocking message bubble shown under the menu bar icon. Unlike NSAlert.runModal it never
/// blocks the app (a modal alert hidden behind other windows used to freeze the menu).
final class Toast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, below button: NSStatusBarButton?, seconds: TimeInterval = 6) {
        hide()

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 300
        let size = label.fittingSize
        let padding: CGFloat = 14
        let frame = NSRect(x: 0, y: 0, width: size.width + 2 * padding, height: size.height + 2 * padding)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        label.frame = frame.insetBy(dx: padding, dy: padding)
        background.addSubview(label)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        background.addGestureRecognizer(click)
        panel.contentView = background

        // Position under the status item, kept on screen.
        if let button, let window = button.window, let screen = window.screen ?? NSScreen.main {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - frame.width / 2
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - frame.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - frame.height - 6))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 12,
                                         y: screen.visibleFrame.maxY - frame.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func clicked() { hide() }
}

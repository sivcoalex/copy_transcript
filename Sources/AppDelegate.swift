import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private lazy var state = AppState() // created once the app has finished launching
    private let toast = Toast()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }

        let hosting = NSHostingController(rootView: PopoverView(state: state))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        state.notify = { [weak self] message in
            guard let self, !self.popover.isShown else { return }
            self.toast.show(message, below: self.statusItem.button, seconds: 8)
        }
        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateIcon(phase) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            toast.hide()
            state.setPopoverVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        state.setPopoverVisible(false)
    }

    // MARK: Status icon

    private func updateIcon(_ phase: AppState.Phase) {
        guard let button = statusItem?.button else { return }
        switch phase {
        case .idle:
            button.image = symbol("mic", description: "Diktafón")
        case .recording:
            button.image = Self.recordingDot
        case .transcribing:
            button.image = symbol("waveform", description: "Diktafón – prepisujem")
        }
    }

    private func symbol(_ name: String, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private static let recordingDot: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let d: CGFloat = 9
            let circle = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2, width: d, height: d)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: circle).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Diktafón – nahrávam"
        return image
    }()
}

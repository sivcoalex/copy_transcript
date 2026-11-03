import AppKit
import AVFoundation
import ServiceManagement

enum Paths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diktafon", isDirectory: true)
    static let models = support.appendingPathComponent("models", isDirectory: true)
    static let vadModel = models.appendingPathComponent("ggml-silero-v6.2.0.bin").path
}

enum ModelChoice: String, CaseIterable {
    case fast, accurate

    var fileName: String {
        switch self {
        case .fast: return "ggml-large-v3-turbo-q8_0.bin"
        case .accurate: return "ggml-large-v3-q5_0.bin"
        }
    }

    var title: String {
        switch self {
        case .fast: return "Rýchly (large-v3-turbo)"
        case .accurate: return "Presnejší (large-v3, ~2× pomalší)"
        }
    }

    var path: String { Paths.models.appendingPathComponent(fileName).path }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, recording, transcribing }

    private let defaults = UserDefaults.standard
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let hotKey = HotKey()
    private let toast = Toast()

    private var statusItem: NSStatusItem!
    private var state: State = .idle { didSet { updateIcon() } }
    private var statusMessage: String?
    private var history: [String] = []
    private var maxDurationTimer: Timer?
    private var shortcutWindow: ShortcutWindowController?

    private static let maxRecordingSeconds: TimeInterval = 15 * 60

    // MARK: Settings

    private var shortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: "shortcut"),
                  let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
            return s
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    private var model: ModelChoice {
        get { ModelChoice(rawValue: defaults.string(forKey: "model") ?? "") ?? .fast }
        set { defaults.set(newValue.rawValue, forKey: "model") }
    }

    /// UID of the chosen microphone; nil = follow the system default input.
    private var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }

    /// Name of the microphone used for the current/last recording.
    private var recordingDeviceName = ""

    private var soundsEnabled: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        hotKey.onPress = { [weak self] in self?.toggle() }
        if !hotKey.register(shortcut) {
            statusMessage = "Skratku \(shortcut.displayString) už používa iná appka – nastav inú."
        }

        setUpLoginItemOnFirstLaunch()

        // Ask for the microphone once, right away, so the first dictation isn't interrupted.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = recorder.stop()
        engine.unloadAndWait()
    }

    // MARK: Dictation

    private func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: NSSound.beep()
        }
    }

    private func startRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.startRecording() } }
            }
            return
        default:
            showMicrophoneDeniedAlert()
            return
        }

        guard model.isAvailable else {
            showError("Chýba súbor modelu \(model.fileName) v priečinku \(Paths.models.path).")
            return
        }

        // A chosen microphone that isn't connected right now falls back to the system default.
        let chosen = inputDeviceUID.flatMap(InputDevice.with(uid:)) ?? InputDevice.automatic()
        state = .recording // block repeated presses while the microphone starts
        startRecorder(device: chosen, attempt: 1)
    }

    /// Core Audio sometimes refuses a device for a moment (e.g. right after another app or
    /// a Bluetooth device switched it), so retry a few times, finally with the system default.
    private func startRecorder(device: InputDevice?, attempt: Int) {
        let device = attempt >= 3 ? nil : device
        recordingDeviceName = (device ?? InputDevice.systemDefault())?.name ?? "neznámy mikrofón"
        do {
            try recorder.start(device: device)
        } catch {
            DiagnosticLog.write("start attempt \(attempt) failed on \"\(recordingDeviceName)\": \(error.localizedDescription)")
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard self?.state == .recording else { return }
                    self?.startRecorder(device: device, attempt: attempt + 1)
                }
            } else {
                state = .idle
                if soundsEnabled { NSSound(named: "Funk")?.play() }
                showError("Mikrofón sa nepodarilo zapnúť (\(error.localizedDescription)). Skús to o chvíľu znova.")
            }
            return
        }
        if attempt > 1 { DiagnosticLog.write("start succeeded on attempt \(attempt)") }
        statusMessage = nil
        // Load the model while the user speaks, so transcription can start immediately.
        engine.preload(modelPath: model.path)

        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Self.maxRecordingSeconds, repeats: false) { [weak self] _ in
            self?.stopAndTranscribe()
        }
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil

        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let peak = AudioRecorder.peak(samples)
        DiagnosticLog.write(String(format: "recorded %.1f s from \"%@\", peak %.4f", seconds, recordingDeviceName, peak))
        guard seconds >= 0.4 else {
            finish(text: "")
            return
        }
        guard peak >= 0.003 else {
            state = .idle
            statusMessage = "Mikrofón „\(recordingDeviceName)“ nič nezachytil."
            if soundsEnabled { NSSound(named: "Funk")?.play() }
            showSilenceAlert()
            return
        }

        state = .transcribing
        engine.transcribe(samples: samples, modelPath: model.path, vadModelPath: Paths.vadModel,
                          language: "sk", vocabulary: Vocabulary.load()) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): self?.finish(text: text)
                case .failure(let error):
                    self?.state = .idle
                    self?.showError(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String) {
        state = .idle
        DiagnosticLog.write("transcribed \(text.count) characters")
        guard !text.isEmpty else {
            statusMessage = "Nič som nezachytil."
            if soundsEnabled { NSSound(named: "Funk")?.play() }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        history.insert(text, at: 0)
        if history.count > 5 { history.removeLast() }
        statusMessage = "Skopírované do schránky."
        if soundsEnabled { NSSound(named: "Pop")?.play() }
    }

    // MARK: Status icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        switch state {
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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        switch state {
        case .idle: status = statusMessage ?? "Pripravený"
        case .recording: status = "Nahrávam (\(recordingDeviceName))…"
        case .transcribing: status = "Prepisujem…"
        }
        menu.addItem(disabled("Diktafón — \(status)"))

        let toggleTitle: String
        switch state {
        case .idle: toggleTitle = "Začať diktovanie"
        case .recording: toggleTitle = "Zastaviť a prepísať"
        case .transcribing: toggleTitle = "Prepisujem…"
        }
        let toggleItem = item(toggleTitle, #selector(menuToggle))
        toggleItem.isEnabled = state != .transcribing
        menu.addItem(toggleItem)
        menu.addItem(disabled("Skratka: \(shortcut.displayString)"))

        if !history.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Posledné prepisy (klik = skopírovať)"))
            for (i, text) in history.enumerated() {
                let short = text.count > 50 ? String(text.prefix(50)) + "…" : text
                let it = item(short, #selector(copyHistory(_:)))
                it.tag = i
                it.toolTip = text
                menu.addItem(it)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Nastaviť skratku…", #selector(openShortcutWindow)))
        menu.addItem(item("Upraviť slovník…", #selector(openVocabulary)))

        let micItem = NSMenuItem(title: "Mikrofón", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let autoName = InputDevice.automatic()?.name ?? "—"
        let auto = item("Automaticky (teraz: \(autoName))", #selector(selectMicrophone(_:)))
        auto.state = inputDeviceUID == nil ? .on : .off
        micMenu.addItem(auto)
        micMenu.addItem(.separator())
        let devices = InputDevice.all()
        for device in devices where !device.isVirtual || device.uid == inputDeviceUID {
            let it = item(device.name, #selector(selectMicrophone(_:)))
            it.representedObject = device.uid
            it.state = device.uid == inputDeviceUID ? .on : .off
            micMenu.addItem(it)
        }
        if let uid = inputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            micMenu.addItem(disabled("Vybraný mikrofón nie je pripojený – používam automatický"))
        }
        micItem.submenu = micMenu
        micItem.isEnabled = state == .idle
        menu.addItem(micItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for choice in ModelChoice.allCases {
            let it = item(choice.title, #selector(selectModel(_:)))
            it.representedObject = choice.rawValue
            it.state = choice == model ? .on : .off
            it.isEnabled = choice.isAvailable && state == .idle
            modelMenu.addItem(it)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let sounds = item("Zvuky", #selector(toggleSounds))
        sounds.state = soundsEnabled ? .on : .off
        menu.addItem(sounds)

        let login = item("Spúšťať po prihlásení", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(disabled(engine.isLoaded ? "Model je v pamäti (uvoľní sa po 3 min)" : "Model nie je v pamäti"))
        menu.addItem(item("Ukončiť Diktafón", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func menuToggle() { toggle() }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history[sender.tag], forType: .string)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = ModelChoice(rawValue: raw) else { return }
        model = choice
        engine.unload()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        inputDeviceUID = sender.representedObject as? String
    }

    @objc private func openVocabulary() {
        _ = Vocabulary.load() // creates the file with defaults if it doesn't exist yet
        NSWorkspace.shared.open(Vocabulary.url)
    }

    @objc private func toggleSounds() { soundsEnabled.toggle() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Nepodarilo sa zmeniť spúšťanie po prihlásení: \(error.localizedDescription)")
        }
    }

    @objc private func openShortcutWindow() {
        if shortcutWindow == nil {
            let controller = ShortcutWindowController(current: shortcut)
            controller.onChange = { [weak self] newShortcut in
                self?.shortcut = newShortcut
                self?.statusMessage = nil
            }
            controller.onRecordingChanged = { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.hotKey.unregister()
                } else if !self.hotKey.register(self.shortcut) {
                    self.showError("Skratku \(self.shortcut.displayString) už používa iná appka alebo systém. Skús inú.")
                }
            }
            shortcutWindow = controller
        }
        shortcutWindow?.current = shortcut
        shortcutWindow?.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func setUpLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: "didSetUpLoginItem") else { return }
        defaults.set(true, forKey: "didSetUpLoginItem")
        try? SMAppService.mainApp.register()
    }

    private func showMicrophoneDeniedAlert() {
        showError("Diktafón nemá prístup k mikrofónu. Povoľ ho v Nastaveniach systému → Súkromie a bezpečnosť → Mikrofón.")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showSilenceAlert() {
        toast.show("Mikrofón „\(recordingDeviceName)“ nič nezachytil – nahrávka bola úplne tichá. "
                   + "Iný mikrofón zvolíš v menu Diktafónu → Mikrofón.", below: statusItem.button, seconds: 8)
    }

    /// Never modal: a blocking alert would freeze the menu bar icon until dismissed.
    private func showError(_ message: String) {
        statusMessage = message
        toast.show(message, below: statusItem.button, seconds: 8)
    }
}

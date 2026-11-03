import AppKit
import AVFoundation
import ServiceManagement

enum Paths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diktafon", isDirectory: true)
    static let models = support.appendingPathComponent("models", isDirectory: true)
    static let vadModel = models.appendingPathComponent("ggml-silero-v6.2.0.bin").path
}

enum ModelChoice: String, CaseIterable, Identifiable {
    case fast, accurate

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .fast: return "ggml-large-v3-turbo-q8_0.bin"
        case .accurate: return "ggml-large-v3-q5_0.bin"
        }
    }

    var title: String {
        switch self {
        case .fast: return "Rýchly"
        case .accurate: return "Presnejší"
        }
    }

    var path: String { Paths.models.appendingPathComponent(fileName).path }
    var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

struct Transcript: Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

/// All dictation logic and settings; observed by the popover UI and the status bar icon.
final class AppState: ObservableObject {
    enum Phase { case idle, recording, transcribing }

    @Published private(set) var phase: Phase = .idle
    @Published var statusMessage: String?
    @Published private(set) var history: [Transcript] = []
    @Published private(set) var recordingStarted: Date?
    /// Recent loudness values (0…1), newest last, for the live waveform.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: AppState.levelCount)
    @Published private(set) var recordingDeviceName = ""
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var automaticDeviceName = ""
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var modelStatus = WhisperEngine.Status()
    @Published private(set) var isCapturingShortcut = false

    @Published var shortcut: Shortcut {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
            registerHotKey()
        }
    }

    @Published var model: ModelChoice {
        didSet {
            defaults.set(model.rawValue, forKey: "model")
            engine.unload()
        }
    }

    /// UID of the chosen microphone; nil = automatic.
    @Published var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }

    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "sounds") }
    }

    /// Shows a message outside the popover (set by the app delegate).
    var notify: ((String) -> Void)?

    static let levelCount = 36
    private static let maxRecordingSeconds: TimeInterval = 15 * 60

    private let defaults = UserDefaults.standard
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let hotKey = HotKey()
    private var maxDurationTimer: Timer?
    private var levelTimer: Timer?
    private var statusTimer: Timer?
    private var shortcutMonitor: Any?

    init(sideEffects: Bool = true) {
        let data = defaults.data(forKey: "shortcut")
        shortcut = data.flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        model = ModelChoice(rawValue: defaults.string(forKey: "model") ?? "") ?? .fast
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        soundsEnabled = defaults.object(forKey: "sounds") as? Bool ?? true

        guard sideEffects else { return }
        hotKey.onPress = { [weak self] in self?.toggle() }
        registerHotKey()
        setUpLoginItemOnFirstLaunch()
        refresh()

        // Ask for the microphone once, right away, so the first dictation isn't interrupted.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    func shutdown() {
        _ = recorder.stop()
        engine.unloadAndWait()
    }

    /// Re-reads things that can change outside the app (devices, login item, model memory).
    func refresh() {
        devices = InputDevice.all().filter { !$0.isVirtual || $0.uid == inputDeviceUID }
        automaticDeviceName = InputDevice.automatic()?.name ?? "—"
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        modelStatus = engine.status
    }

    /// Keeps the model status fresh while the popover is open.
    func setPopoverVisible(_ visible: Bool) {
        statusTimer?.invalidate()
        statusTimer = nil
        if visible {
            refresh()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.modelStatus = self.engine.status
            }
        } else {
            endShortcutCapture()
        }
    }

    // MARK: Dictation

    func toggle() {
        switch phase {
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
            fail("Diktafón nemá prístup k mikrofónu. Povoľ ho v Nastaveniach systému → Súkromie a bezpečnosť → Mikrofón.")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        guard model.isAvailable else {
            fail("Chýba súbor modelu \(model.fileName) v priečinku \(Paths.models.path).")
            return
        }

        // A chosen microphone that isn't connected right now falls back to the automatic choice.
        let chosen = inputDeviceUID.flatMap(InputDevice.with(uid:)) ?? InputDevice.automatic()
        statusMessage = nil
        phase = .recording // block repeated presses while the microphone starts
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
                    guard self?.phase == .recording else { return }
                    self?.startRecorder(device: device, attempt: attempt + 1)
                }
            } else {
                phase = .idle
                playSound("Funk")
                fail("Mikrofón sa nepodarilo zapnúť (\(error.localizedDescription)). Skús to o chvíľu znova.")
            }
            return
        }
        if attempt > 1 { DiagnosticLog.write("start succeeded on attempt \(attempt)") }

        recordingStarted = Date()
        // Load the model while the user speaks, so transcription can start immediately.
        engine.preload(modelPath: model.path)

        levels = Array(repeating: 0, count: Self.levelCount)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Speech RMS is small; scale it up so normal speaking fills most of the meter.
            let level = min(1, sqrt(self.recorder.currentLevel) * 2.2)
            self.levels.removeFirst()
            self.levels.append(level)
        }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Self.maxRecordingSeconds, repeats: false) { [weak self] _ in
            self?.stopAndTranscribe()
        }
    }

    private func stopAndTranscribe() {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        recordingStarted = nil

        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let peak = AudioRecorder.peak(samples)
        DiagnosticLog.write(String(format: "recorded %.1f s from \"%@\", peak %.4f", seconds, recordingDeviceName, peak))
        guard seconds >= 0.4 else {
            finish(text: "")
            return
        }
        guard peak >= 0.003 else {
            phase = .idle
            playSound("Funk")
            fail("Mikrofón „\(recordingDeviceName)“ nič nezachytil – nahrávka bola úplne tichá. Iný mikrofón zvolíš v nastaveniach.")
            return
        }

        phase = .transcribing
        engine.transcribe(samples: samples, modelPath: model.path, vadModelPath: Paths.vadModel,
                          language: "sk", vocabulary: Vocabulary.load()) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text): self?.finish(text: text)
                case .failure(let error):
                    self?.phase = .idle
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    private func finish(text: String) {
        phase = .idle
        modelStatus = engine.status
        DiagnosticLog.write("transcribed \(text.count) characters")
        guard !text.isEmpty else {
            statusMessage = "Nič som nezachytil."
            playSound("Funk")
            return
        }
        copyToClipboard(text)
        history.insert(Transcript(text: text, date: Date()), at: 0)
        if history.count > 5 { history.removeLast() }
        statusMessage = "Skopírované do schránky"
        playSound("Pop")
    }

    // MARK: Actions

    func copy(_ transcript: Transcript) {
        copyToClipboard(transcript.text)
    }

    func clearHistory() {
        history.removeAll()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            fail("Nepodarilo sa zmeniť spúšťanie po prihlásení: \(error.localizedDescription)")
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    func openVocabulary() {
        _ = Vocabulary.load() // creates the file with defaults if it doesn't exist yet
        NSWorkspace.shared.open(Vocabulary.url)
    }

    // MARK: Shortcut capture

    func beginShortcutCapture() {
        guard shortcutMonitor == nil else { return }
        hotKey.unregister()
        isCapturingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.endShortcutCapture()
            } else if let captured = Shortcut(event: event) {
                self.endShortcutCapture(newShortcut: captured)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func endShortcutCapture(newShortcut: Shortcut? = nil) {
        guard let monitor = shortcutMonitor else { return }
        NSEvent.removeMonitor(monitor)
        shortcutMonitor = nil
        isCapturingShortcut = false
        if let newShortcut {
            shortcut = newShortcut // didSet registers it
        } else {
            registerHotKey()
        }
    }

    /// Fills the state with sample data for rendering UI snapshots (--snapshot).
    func loadSnapshotData(phase: Phase) {
        self.phase = phase
        refresh()
        history = [
            Transcript(text: "Dnes som celý deň programoval v Claude Code a potom som spravil commit a otvoril pull request na GitHub.", date: Date().addingTimeInterval(-120)),
            Transcript(text: "Zajtra musíme spraviť deploy na server a pozrieť sa na feedback od klienta.", date: Date().addingTimeInterval(-900)),
        ]
        modelStatus = WhisperEngine.Status(loaded: true, unloadAt: Date().addingTimeInterval(154))
        if phase == .recording {
            recordingStarted = Date().addingTimeInterval(-12)
            recordingDeviceName = "Mikrofón MacBook Pro"
            levels = (0..<Self.levelCount).map { i -> Float in
                let x = Double(i)
                let wave: Double = abs(sin(x * 0.55)) * (0.5 + 0.5 * cos(x * 0.17))
                return Float(0.15 + 0.75 * wave)
            }
        } else if phase == .idle {
            statusMessage = "Skopírované do schránky"
        }
    }

    // MARK: Helpers

    private func registerHotKey() {
        guard shortcutMonitor == nil else { return }
        if !hotKey.register(shortcut) {
            fail("Skratku \(shortcut.displayString) už používa iná appka alebo systém. Nastav inú.")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func playSound(_ name: String) {
        if soundsEnabled { NSSound(named: name)?.play() }
    }

    /// Never modal: a blocking alert would freeze the menu bar icon until dismissed.
    private func fail(_ message: String) {
        statusMessage = message
        notify?(message)
    }

    private func setUpLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: "didSetUpLoginItem") else { return }
        defaults.set(true, forKey: "didSetUpLoginItem")
        try? SMAppService.mainApp.register()
    }
}

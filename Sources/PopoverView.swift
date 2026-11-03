import SwiftUI

/// Content of the window that opens from the menu bar icon.
struct PopoverView: View {
    @ObservedObject var state: AppState
    @State private var showSettings: Bool

    init(state: AppState, showSettings: Bool = false) {
        self.state = state
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(state: state) { withAnimation(.snappy) { showSettings = false } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainView(state: state) { withAnimation(.snappy) { showSettings = true } }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Main screen

private struct MainView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Diktafón") {
                IconButton(systemImage: "gearshape", help: "Nastavenia", action: openSettings)
            } leading: {
                AppBadge()
            }

            RecordSection(state: state)
                .padding(.vertical, 18)

            Divider().padding(.horizontal, 14)

            HistorySection(state: state)
                .padding(14)

            Divider()
            Footer(state: state)
        }
    }
}

private struct RecordSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            RecordButton(phase: state.phase, level: state.levels.last ?? 0) { state.toggle() }

            VStack(spacing: 6) {
                statusLine
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                detailLine
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Waveform(levels: state.levels, active: state.phase == .recording)
                .frame(height: 26)
                .padding(.horizontal, 28)
                .opacity(state.phase == .recording ? 1 : 0.35)
        }
        .animation(.easeInOut(duration: 0.2), value: state.phase)
    }

    @ViewBuilder private var statusLine: some View {
        switch state.phase {
        case .idle:
            if let message = state.statusMessage {
                Text(message)
                    .foregroundStyle(message == "Skopírované do schránky" ? Color.green : Color.primary)
            } else {
                Text("Pripravený na diktovanie")
            }
        case .recording:
            if let start = state.recordingStarted {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("Nahrávam · \(Self.duration(context.date.timeIntervalSince(start)))")
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            } else {
                Text("Zapínam mikrofón…")
            }
        case .transcribing:
            Text("Prepisujem…")
        }
    }

    @ViewBuilder private var detailLine: some View {
        switch state.phase {
        case .idle:
            HStack(spacing: 5) {
                Text("Klikni alebo stlač")
                KeyCap(text: state.shortcut.displayString)
            }
        case .recording:
            Label(state.recordingDeviceName, systemImage: "mic")
        case .transcribing:
            Text("Text sa po dokončení skopíruje do schránky")
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordButton: View {
    let phase: AppState.Phase
    let level: Float
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Halo that breathes with the voice while recording.
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 84, height: 84)
                    .scaleEffect(phase == .recording ? 1 + CGFloat(level) * 0.35 : 0.8)
                    .opacity(phase == .recording ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: level)

                Circle()
                    .fill(fill)
                    .frame(width: 64, height: 64)
                    .shadow(color: phase == .transcribing ? .clear : .red.opacity(0.35), radius: hovering ? 10 : 6, y: 2)

                switch phase {
                case .idle:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                case .recording:
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 20, height: 20)
                case .transcribing:
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(width: 92, height: 92)
            .scaleEffect(hovering && phase != .transcribing ? 1.04 : 1)
            .animation(.spring(duration: 0.25), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing)
        .onHover { hovering = $0 }
        .help(phase == .recording ? "Zastaviť a prepísať" : "Začať diktovanie")
    }

    private var fill: AnyShapeStyle {
        switch phase {
        case .idle, .recording: return AnyShapeStyle(Color.red.gradient)
        case .transcribing: return AnyShapeStyle(Color.secondary.opacity(0.15))
        }
    }
}

/// Scrolling bar meter of recent loudness.
private struct Waveform: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 3
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(active ? Color.red.opacity(0.45 + Double(levels[i]) * 0.55) : Color.secondary.opacity(0.35))
                        .frame(width: barWidth, height: max(3, geo.size.height * CGFloat(levels[i])))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.07), value: levels)
        }
    }
}

private struct HistorySection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Posledné prepisy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !state.history.isEmpty {
                    Button("Vymazať") { withAnimation { state.clearHistory() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if state.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("Zatiaľ tu nič nie je.\nTvoje prepisy sa zobrazia tu.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.history) { item in
                            HistoryRow(item: item) { state.copy(item) }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: state.history.count <= 2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.history.map(\.id))
    }
}

private struct HistoryRow: View {
    let item: Transcript
    let copy: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.date, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .opacity(hovering || copied ? 1 : 0.5)
                    .frame(width: 16)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.045))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Klikni pre skopírovanie celého textu")
    }
}

private struct Footer: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.modelStatus.loaded ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Group {
                if state.modelStatus.loaded, let unloadAt = state.modelStatus.unloadAt {
                    Text("Model v pamäti · uvoľní sa o \(RecordSection.duration(unloadAt.timeIntervalSinceNow))")
                        .monospacedDigit()
                } else if state.modelStatus.loaded {
                    Text("Model v pamäti")
                } else {
                    Text("Model nie je v pamäti")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            Button("Ukončiť") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Settings screen

private struct SettingsView: View {
    @ObservedObject var state: AppState
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Nastavenia") {
                Color.clear.frame(width: 26, height: 26)
            } leading: {
                IconButton(systemImage: "chevron.left", help: "Späť", action: back)
            }

            VStack(spacing: 2) {
                SettingRow(icon: "command", title: "Skratka") {
                    Button {
                        state.isCapturingShortcut ? state.endShortcutCapture() : state.beginShortcutCapture()
                    } label: {
                        Text(state.isCapturingShortcut ? "Stlač skratku…" : state.shortcut.displayString)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .frame(minWidth: 96)
                    }
                    .controlSize(.regular)
                    .help("Klikni a stlač novú kombináciu (Esc zruší)")
                }

                SettingRow(icon: "mic", title: "Mikrofón") {
                    Picker("", selection: Binding(
                        get: { state.inputDeviceUID ?? "" },
                        set: { state.inputDeviceUID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Automaticky (\(state.automaticDeviceName))").tag("")
                        Divider()
                        ForEach(state.devices, id: \.uid) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if let uid = state.inputDeviceUID, !state.devices.contains(where: { $0.uid == uid }) {
                            Text("Odpojený mikrofón").tag(uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 196)
                    .disabled(state.phase != .idle)
                }

                SettingRow(icon: "cpu", title: "Model") {
                    Picker("", selection: Binding(
                        get: { state.model },
                        set: { if $0.isAvailable { state.model = $0 } }
                    )) {
                        ForEach(ModelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(state.phase != .idle)
                }
                if !ModelChoice.accurate.isAvailable {
                    Text("Presnejší model nie je stiahnutý (inštalácia s --presny).")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }

                SettingRow(icon: "character.book.closed", title: "Slovník") {
                    Button("Upraviť…") { state.openVocabulary() }
                }

                SettingRow(icon: "speaker.wave.2", title: "Zvuky") {
                    Toggle("", isOn: $state.soundsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                SettingRow(icon: "power", title: "Spúšťať po prihlásení") {
                    Toggle("", isOn: Binding(get: { state.loginItemEnabled }, set: { state.setLoginItem($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .padding(.vertical, 10)

            Divider()
            Text("Diktafón 1.1 · prepis beží iba na tomto Macu")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Shared pieces

private struct Header<Trailing: View, Leading: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

private struct AppBadge: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.gradient))
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
            )
    }
}

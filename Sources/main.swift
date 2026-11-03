import AppKit
import SwiftUI

/// Physical memory footprint of this process in MB (what Activity Monitor shows as "Memory").
func memoryFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

// Self-test without UI: Diktafon --transcribe <audio file> [fast|accurate]
// Transcribes twice with an unload in between to exercise the load → free → reload cycle.
let args = CommandLine.arguments
// UI snapshots without the menu bar: Diktafon --snapshot <output dir>
if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
    _ = NSApplication.shared
    let dir = URL(fileURLWithPath: args[i + 1])
    let cases: [(String, AppState.Phase, Bool, Bool)] = [
        ("empty", .idle, false, true), ("idle", .idle, false, false), ("recording", .recording, false, false),
        ("transcribing", .transcribing, false, false), ("settings", .idle, true, false),
    ]
    for (name, phase, settings, empty) in cases {
        for dark in [false, true] {
            let state = AppState(sideEffects: false)
            if !empty { state.loadSnapshotData(phase: phase) } else { state.refresh() }
            let host = NSHostingView(rootView: PopoverView(state: state, showSettings: settings))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)
            window.contentView = host
            host.wantsLayer = true
            host.layer?.backgroundColor = window.backgroundColor.cgColor
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = window.contentView?.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            window.contentView?.cacheDisplay(in: host.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
    exit(0)
}
if args.contains("--list-devices") {
    let def = InputDevice.systemDefault()
    for d in InputDevice.all() {
        print("\(d.uid == def?.uid ? "*" : " ") \(d.name)\(d.isBuiltIn ? " [vstavaný]" : "")\(d.isVirtual ? " [virtuálny]" : "")  (\(d.uid))")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
    let url = URL(fileURLWithPath: args[i + 1])
    let choice = args.count > i + 2 ? ModelChoice(rawValue: args[i + 2]) ?? .fast : .fast
    do {
        let samples = try AudioRecorder.load(fileURL: url)
        let engine = WhisperEngine()
        print(String(format: "[pamäť na začiatku: %.0f MB]", memoryFootprintMB()))
        for round in 1...2 {
            let done = DispatchSemaphore(value: 0)
            let start = Date()
            engine.transcribe(samples: samples, modelPath: choice.path, vadModelPath: Paths.vadModel, language: "sk",
                              vocabulary: Vocabulary.load()) { result in
                switch result {
                case .success(let text): print(text)
                case .failure(let error): print("CHYBA: \(error.localizedDescription)")
                }
                done.signal()
            }
            done.wait()
            print(String(format: "[kolo %d: %.1f s audio, %.1f s spracovanie, pamäť s modelom: %.0f MB]", round,
                         Double(samples.count) / AudioRecorder.sampleRate, Date().timeIntervalSince(start),
                         memoryFootprintMB()))
            engine.unloadAndWait()
            print(String(format: "[po uvoľnení modelu: %.0f MB]", memoryFootprintMB()))
        }
        exit(0)
    } catch {
        print("CHYBA: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AVFoundation

/// Records the system default input device as 16 kHz mono Float32 (what Whisper expects).
/// A fresh AVAudioEngine is created for every recording so the microphone is fully released
/// when recording stops and a changed default input device is always picked up.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case selectDevice(OSStatus)
        case noFormat
        case noConverter

        var errorDescription: String? {
            switch self {
            case .selectDevice(let status): return "mikrofón sa nedal vybrať, kód \(status)"
            case .noFormat: return "mikrofón nevracia žiadny zvukový formát"
            case .noConverter: return "nepodporovaný zvukový formát"
            }
        }
    }

    static let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()

    var isRecording: Bool { engine != nil }

    /// Starts recording from `device`, or from the system default input when nil.
    func start(device: InputDevice?) throws {
        lock.withLock { samples.removeAll(keepingCapacity: false) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw RecorderError.selectDevice(status) }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noFormat }

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                      channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw RecorderError.noConverter }
        let ratio = Self.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// Stops recording, releases the microphone and returns the captured audio.
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock {
            let result = samples
            samples = []
            return result
        }
    }

    /// Loudest absolute sample value (0…1); near zero means the microphone delivered silence.
    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// Loads an audio file and converts it to 16 kHz mono (used by the --transcribe self-test).
    static func load(fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else { return [] }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 64
        let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

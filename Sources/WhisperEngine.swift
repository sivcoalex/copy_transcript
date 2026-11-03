import Foundation

/// Wraps whisper.cpp. The model is loaded lazily (when recording starts) and
/// released from memory after a period of inactivity or under memory pressure.
final class WhisperEngine {
    enum EngineError: LocalizedError {
        case modelMissing(String)
        case loadFailed
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing(let path): return "Model sa nenašiel: \(path)"
            case .loadFailed: return "Model sa nepodarilo načítať."
            case .transcriptionFailed: return "Prepis zlyhal."
            }
        }
    }

    /// How long the model stays in memory after the last use.
    var idleUnloadAfter: TimeInterval = 180

    private let queue = DispatchQueue(label: "sk.diktafon.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private var unloadTimer: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var busy = false

    init() {
        whisper_log_set({ _, _, _ in }, nil)

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.busy else { return }
            self.unloadLocked()
        }
        source.resume()
        memoryPressure = source
    }

    deinit { unloadLocked() }

    var isLoaded: Bool { queue.sync { ctx != nil } }

    /// Starts loading the model in the background so it's ready by the time recording stops.
    func preload(modelPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelUnloadTimer()
            _ = try? self.ensureLoaded(modelPath)
        }
    }

    func transcribe(samples: [Float], modelPath: String, vadModelPath: String?, language: String,
                    vocabulary: Vocabulary = Vocabulary(parsing: ""),
                    completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelUnloadTimer()
            self.busy = true
            defer {
                self.busy = false
                self.scheduleUnload()
            }
            do {
                let ctx = try self.ensureLoaded(modelPath)
                let text = try self.run(ctx: ctx, samples: samples, vadModelPath: vadModelPath, language: language,
                                        prompt: vocabulary.prompt)
                completion(.success(vocabulary.apply(to: text)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func unload() {
        queue.async { [weak self] in self?.unloadLocked() }
    }

    /// Frees the model and waits; must be called before the process exits
    /// (ggml's Metal backend asserts if a context is still alive at exit).
    func unloadAndWait() {
        queue.sync { unloadLocked() }
    }

    // MARK: - Private (always on `queue`)

    private func ensureLoaded(_ path: String) throws -> OpaquePointer {
        if let ctx, loadedPath == path { return ctx }
        unloadLocked()
        guard FileManager.default.fileExists(atPath: path) else { throw EngineError.modelMissing(path) }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let newCtx = whisper_init_from_file_with_params(path, cparams) else { throw EngineError.loadFailed }
        ctx = newCtx
        loadedPath = path
        return newCtx
    }

    private func run(ctx: OpaquePointer, samples: [Float], vadModelPath: String?, language: String,
                     prompt: String?) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        params.translate = false
        params.no_timestamps = true
        params.no_context = true
        params.single_segment = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true

        // C strings must outlive whisper_full.
        let cLanguage = strdup(language)
        let cPrompt = prompt.map { strdup($0) }
        let useVAD = vadModelPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let cVAD = useVAD ? vadModelPath.map { strdup($0) } : nil
        defer {
            free(cLanguage)
            if let cPrompt { free(cPrompt) }
            if let cVAD { free(cVAD) }
        }
        params.language = UnsafePointer(cLanguage)
        if let cPrompt {
            params.initial_prompt = UnsafePointer(cPrompt)
            // Keep the hint for every 30 s window of long dictations, not just the first.
            params.carry_initial_prompt = true
        }
        if let cVAD {
            params.vad = true
            params.vad_model_path = UnsafePointer(cVAD)
        }

        let status = samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        guard status == 0 else { throw EngineError.transcriptionFailed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleUnload() {
        cancelUnloadTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleUnloadAfter)
        timer.setEventHandler { [weak self] in self?.unloadLocked() }
        timer.resume()
        unloadTimer = timer
    }

    private func cancelUnloadTimer() {
        unloadTimer?.cancel()
        unloadTimer = nil
    }

    private func unloadLocked() {
        cancelUnloadTimer()
        guard let ctx else { return }
        whisper_free(ctx)
        self.ctx = nil
        loadedPath = nil
        // Hand freed heap pages back to the system right away.
        malloc_zone_pressure_relief(nil, 0)
    }
}

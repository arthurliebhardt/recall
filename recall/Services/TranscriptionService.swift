import Foundation
import os
import WhisperKit

private let logger = Logger(subsystem: "com.summarizecontent.app", category: "WhisperKit")

@Observable
@MainActor
final class TranscriptionService {

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Whisper model is not loaded."
            case .transcriptionFailed(let reason):
                return "Transcription failed: \(reason)"
            }
        }
    }

    enum ModelState: Equatable {
        case notLoaded
        case downloading(Double)
        case loading
        case loaded(String)
        case error(String)

        var isReady: Bool {
            if case .loaded = self { return true }
            return false
        }

        var modelName: String? {
            if case .loaded(let name) = self { return name }
            return nil
        }
    }

    nonisolated static let defaultModel = WhisperKit.recommendedModels().default
    private static var huggingFaceCacheDirectory: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = cachesDirectory.appendingPathComponent("huggingface", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private static let requiredModelComponents = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    private(set) var modelState: ModelState = .notLoaded
    private(set) var transcriptionProgress: Double = 0
    private(set) var isTranscribing = false

    private var whisperKit: WhisperKit?

    // MARK: - Model Management

    func loadModel(_ variant: String = defaultModel) async {
        let supportedModels = Set(WhisperKit.recommendedModels().supported)
        let resolvedVariant = supportedModels.contains(variant) ? variant : Self.defaultModel
        if resolvedVariant != variant {
            logger.notice("[WhisperKit] Falling back from unsupported model \(variant) to \(resolvedVariant)")
        }

        modelState = .downloading(0)
        logger.notice("[WhisperKit] Starting to load model: \(resolvedVariant)")

        do {
            let modelFolder: URL
            if let cachedModelFolder = Self.cachedModelFolder(for: resolvedVariant) {
                logger.notice("[WhisperKit] Reusing cached model at: \(cachedModelFolder.path)")
                modelFolder = cachedModelFolder
            } else {
                // Download the model with progress tracking only when the cache is incomplete.
                logger.notice("[WhisperKit] Downloading model files...")
                modelFolder = try await WhisperKit.download(
                    variant: resolvedVariant,
                    downloadBase: Self.huggingFaceCacheDirectory,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.modelState = .downloading(progress.fractionCompleted)
                        }
                    }
                )
                logger.notice("[WhisperKit] Download complete at: \(modelFolder.path)")
            }

            // Neural Engine specialization can stall for minutes on some macOS setups.
            // Favor GPU-backed loading here so the first startup is predictable.
            modelState = .loading
            logger.notice("[WhisperKit] Loading model into memory with GPU-backed compute...")
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU,
                    prefillCompute: .cpuOnly
                ),
                verbose: false,
                logLevel: .none
            )
            let kit = try await WhisperKit(config)
            logger.notice("[WhisperKit] WhisperKit initialized successfully")
            self.whisperKit = kit
            modelState = .loaded(resolvedVariant)
        } catch {
            logger.notice("[WhisperKit] Error loading model: \(error)")
            modelState = .error(error.localizedDescription)
        }
    }

    func unloadModel() {
        whisperKit = nil
        modelState = .notLoaded
    }

    /// Fetch available model variants from the HuggingFace repo.
    func fetchAvailableModels() async -> [String] {
        do {
            return try await WhisperKit.fetchAvailableModels(
                downloadBase: Self.huggingFaceCacheDirectory
            )
        } catch {
            return []
        }
    }

    /// Get recommended models for this device.
    func recommendedModels() -> (defaultModel: String, supported: [String]) {
        let rec = WhisperKit.recommendedModels()
        return (rec.default, rec.supported)
    }

    private static func cachedModelFolder(for variant: String) -> URL? {
        let modelFolder = huggingFaceCacheDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        let configFile = modelFolder.appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return nil
        }

        let hasAllCoreComponents = requiredModelComponents.allSatisfy { component in
            FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(component).path)
        }

        return hasAllCoreComponents ? modelFolder : nil
    }

    /// Strip Whisper special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    private static func cleanWhisperText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transcription

    func transcribe(audioPath: String) async throws -> (segments: [TranscriptionSegment], fullText: String) {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        isTranscribing = true
        transcriptionProgress = 0

        defer {
            isTranscribing = false
            transcriptionProgress = 1.0
        }

        let options = DecodingOptions(
            task: .transcribe,
            temperature: 0.0,                   // Greedy decoding = fastest
            usePrefillPrompt: true,              // Skip predicting task/language tokens
            usePrefillCache: true,               // Pre-populate KV cache
            skipSpecialTokens: true,             // Clean output, no <|tokens|>
            wordTimestamps: true,                // Word-level timestamps for highlighting
            suppressBlank: true,                 // Skip blank segments
            concurrentWorkerCount: 16,           // Parallel chunk processing
            chunkingStrategy: .vad               // Split on silence → parallel decode
        )

        let startTime = CFAbsoluteTimeGetCurrent()

        let results = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options,
            callback: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.transcriptionProgress = min(0.95, Double(progress.windowId) * 0.05)
                }
                return true
            }
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.notice("[WhisperKit] Transcription completed in \(String(format: "%.1f", elapsed))s, \(results.count) result(s)")

        // Collect segments from all result chunks
        var allSegments: [TranscriptionSegment] = []
        for result in results {
            for seg in result.segments {
                let cleaned = Self.cleanWhisperText(seg.text)
                guard !cleaned.isEmpty else { continue }

                // Collect word-level timings
                var words: [TranscriptionWord] = []
                if let wordTimings = seg.words {
                    for wt in wordTimings {
                        let w = wt.word.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !w.isEmpty else { continue }
                        words.append(TranscriptionWord(
                            word: w,
                            startTime: TimeInterval(wt.start),
                            endTime: TimeInterval(wt.end)
                        ))
                    }
                }

                allSegments.append(TranscriptionSegment(
                    startTime: TimeInterval(seg.start),
                    endTime: TimeInterval(seg.end),
                    text: cleaned,
                    words: words
                ))
            }
        }

        // Build full text from cleaned segments
        let fullText = allSegments.map(\.text).joined(separator: " ")

        return (allSegments, fullText)
    }
}

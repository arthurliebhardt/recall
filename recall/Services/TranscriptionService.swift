import AVFAudio
import CoreMedia
import Foundation
import os
#if canImport(Speech)
import Speech
#endif
import WhisperKit

private let logger = Logger(subsystem: "com.summarizecontent.app", category: "Transcription")

@Observable
@MainActor
final class TranscriptionService {
    enum Backend: String, CaseIterable, Identifiable {
        case appleSpeech
        case whisperKit

        var id: Self { self }

        var title: String {
            switch self {
            case .appleSpeech:
                return "Apple Speech"
            case .whisperKit:
                return "WhisperKit"
            }
        }

        var detail: String {
            switch self {
            case .appleSpeech:
                return "Uses Apple's on-device SpeechAnalyzer transcription on macOS 26+."
            case .whisperKit:
                return "Uses a local Whisper model downloaded from Hugging Face."
            }
        }
    }

    enum PerformanceProfile: String, CaseIterable, Identifiable {
        case fast
        case accurate

        var id: Self { self }

        var title: String {
            switch self {
            case .fast:
                return "Fast"
            case .accurate:
                return "Accurate"
            }
        }

        var detail: String {
            switch self {
            case .fast:
                return "Best throughput. Uses a single greedy decode pass."
            case .accurate:
                return "Slower, but retries uncertain segments up to five times."
            }
        }

        var temperatureFallbackCount: Int {
            switch self {
            case .fast:
                return 0
            case .accurate:
                return 5
            }
        }
    }

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case transcriptionFailed(String)
        case backendUnavailable(String)
        case unsupportedLocale(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The selected transcription backend is not ready."
            case .transcriptionFailed(let reason):
                return "Transcription failed: \(reason)"
            case .backendUnavailable(let reason):
                return reason
            case .unsupportedLocale(let reason):
                return reason
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
    nonisolated static let defaultPerformanceProfile: PerformanceProfile = .fast
    private static let backendDefaultsKey = "transcriptionBackend"
    nonisolated static let systemLocalePreferenceValue = "__system__"
    private static let appleLocalePreferenceDefaultsKey = "appleSpeechLocalePreference"
    private static let performanceProfileDefaultsKey = "transcriptionPerformanceProfile"
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

    private(set) var selectedBackend: Backend
    private(set) var modelState: ModelState
    private(set) var transcriptionProgress: Double = 0
    private(set) var isTranscribing = false
    private(set) var appleLocalePreference: String
    private(set) var availableAppleLocales: [Locale] = []
    private(set) var installedAppleLocaleIdentifiers: Set<String> = []
    private(set) var resolvedAppleLocaleIdentifier: String?

    private var whisperModelState: ModelState = .notLoaded
    private var appleModelState: ModelState = .notLoaded
    private var whisperKit: WhisperKit?
    private var reservedAppleLocaleIdentifier: String?
    private var preparedAppleLocaleIdentifier: String?

    init() {
        let backend = Self.resolveBackend(UserDefaults.standard.string(forKey: Self.backendDefaultsKey))
        let localePreference = Self.resolveAppleLocalePreference(
            UserDefaults.standard.string(forKey: Self.appleLocalePreferenceDefaultsKey)
        )
        self.selectedBackend = backend
        self.appleLocalePreference = localePreference
        self.modelState = .notLoaded
        self.modelState = state(for: backend)
    }

    var availableBackends: [Backend] {
        var backends: [Backend] = [.whisperKit]
        if Self.isBackendSupported(.appleSpeech) {
            backends.insert(.appleSpeech, at: 0)
        }
        return backends
    }

    var isReadyForTranscription: Bool {
        modelState.isReady
    }

    var readinessErrorDescription: String {
        switch selectedBackend {
        case .appleSpeech:
            switch modelState {
            case .error(let message):
                return message
            default:
                return "Apple Speech is not ready. Open Settings and prepare the transcription backend first."
            }
        case .whisperKit:
            switch modelState {
            case .error(let message):
                return message
            default:
                return "Whisper model is not loaded. Open Settings and load a model first."
            }
        }
    }

    nonisolated static var defaultBackend: Backend {
        if isBackendSupported(.appleSpeech) {
            return .appleSpeech
        }
        return .whisperKit
    }

    nonisolated static func resolveBackend(_ rawValue: String?) -> Backend {
        guard let rawValue, let backend = Backend(rawValue: rawValue), isBackendSupported(backend) else {
            return defaultBackend
        }
        return backend
    }

    nonisolated static func resolveAppleLocalePreference(_ rawValue: String?) -> String {
        guard let rawValue else { return systemLocalePreferenceValue }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? systemLocalePreferenceValue : trimmed
    }

    nonisolated static func isBackendSupported(_ backend: Backend) -> Bool {
        switch backend {
        case .whisperKit:
            return true
        case .appleSpeech:
#if canImport(Speech)
            if #available(macOS 26.0, *) {
                return SpeechTranscriber.isAvailable
            }
#endif
            return false
        }
    }

    // MARK: - Model Management

    func setBackend(_ backend: Backend) async {
        let resolvedBackend = Self.isBackendSupported(backend) ? backend : .whisperKit
        guard resolvedBackend != selectedBackend else {
            if resolvedBackend == .appleSpeech {
                await refreshAppleLocaleInventory()
            }
            syncActiveState()
            return
        }

        if selectedBackend == .appleSpeech {
            appleModelState = .notLoaded
            preparedAppleLocaleIdentifier = nil
            await releaseAppleLocaleReservation()
        }

        selectedBackend = resolvedBackend
        UserDefaults.standard.set(resolvedBackend.rawValue, forKey: Self.backendDefaultsKey)
        if resolvedBackend == .appleSpeech {
            await refreshAppleLocaleInventory()
        }
        syncActiveState()
    }

    func setAppleLocalePreference(_ preference: String) async {
        let resolvedPreference = Self.resolveAppleLocalePreference(preference)
        guard resolvedPreference != appleLocalePreference else {
            await refreshAppleLocaleInventory()
            return
        }

        if preparedAppleLocaleIdentifier != nil || reservedAppleLocaleIdentifier != nil {
            appleModelState = .notLoaded
            preparedAppleLocaleIdentifier = nil
            await releaseAppleLocaleReservation()
        }

        appleLocalePreference = resolvedPreference
        UserDefaults.standard.set(resolvedPreference, forKey: Self.appleLocalePreferenceDefaultsKey)
        await refreshAppleLocaleInventory()
        syncActiveState()
    }

    func refreshAppleLocaleInventory() async {
#if canImport(Speech)
        guard #available(macOS 26.0, *) else {
            availableAppleLocales = []
            installedAppleLocaleIdentifiers = []
            resolvedAppleLocaleIdentifier = nil
            return
        }

        guard SpeechTranscriber.isAvailable else {
            availableAppleLocales = []
            installedAppleLocaleIdentifiers = []
            resolvedAppleLocaleIdentifier = nil
            return
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
            .sorted { Self.displayName(for: $0).localizedCaseInsensitiveCompare(Self.displayName(for: $1)) == .orderedAscending }
        let installedLocales = await SpeechTranscriber.installedLocales

        availableAppleLocales = supportedLocales
        installedAppleLocaleIdentifiers = Set(installedLocales.map(\.identifier))

        await normalizeAppleLocalePreference(using: supportedLocales)
        resolvedAppleLocaleIdentifier = (try? await supportedAppleLocale())?.identifier
#else
        availableAppleLocales = []
        installedAppleLocaleIdentifiers = []
        resolvedAppleLocaleIdentifier = nil
#endif
    }

    func prepareSelectedBackend(whisperVariant: String = defaultModel) async {
        let persistedBackend = Self.resolveBackend(UserDefaults.standard.string(forKey: Self.backendDefaultsKey))
        if persistedBackend != selectedBackend {
            await setBackend(persistedBackend)
        } else {
            syncActiveState()
        }

        switch selectedBackend {
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                await prepareAppleSpeech()
            } else {
                updateAppleState(.error("Apple Speech requires macOS 26 or later."))
            }
        case .whisperKit:
            await loadWhisperModel(whisperVariant)
        }
    }

    func unloadSelectedBackend() async {
        switch selectedBackend {
        case .appleSpeech:
            appleModelState = .notLoaded
            preparedAppleLocaleIdentifier = nil
            await releaseAppleLocaleReservation()
#if canImport(Speech)
            if #available(macOS 26.0, *) {
                await SpeechModels.endRetention()
            }
#endif
        case .whisperKit:
            whisperKit = nil
            whisperModelState = .notLoaded
        }

        transcriptionProgress = 0
        syncActiveState()
    }

    private func loadWhisperModel(_ variant: String = defaultModel) async {
        let supportedModels = Set(WhisperKit.recommendedModels().supported)
        let resolvedVariant = supportedModels.contains(variant) ? variant : Self.defaultModel
        if resolvedVariant != variant {
            logger.notice("[WhisperKit] Falling back from unsupported model \(variant) to \(resolvedVariant)")
        }

        updateWhisperState(.downloading(0))
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
            updateWhisperState(.loading)
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
            updateWhisperState(.loaded(resolvedVariant))
        } catch {
            logger.notice("[WhisperKit] Error loading model: \(error)")
            updateWhisperState(.error(error.localizedDescription))
        }
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

    static func resolvePerformanceProfile(_ rawValue: String?) -> PerformanceProfile {
        guard let rawValue, let profile = PerformanceProfile(rawValue: rawValue) else {
            return defaultPerformanceProfile
        }
        return profile
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
        guard modelState.isReady else {
            throw TranscriptionError.backendUnavailable(readinessErrorDescription)
        }

        isTranscribing = true
        transcriptionProgress = 0

        defer {
            isTranscribing = false
            transcriptionProgress = 1.0
        }

        let profile = Self.resolvePerformanceProfile(
            UserDefaults.standard.string(forKey: Self.performanceProfileDefaultsKey)
        )

        switch selectedBackend {
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return try await transcribeWithAppleSpeech(audioPath: audioPath, profile: profile)
            }
            throw TranscriptionError.backendUnavailable("Apple Speech requires macOS 26 or later.")
        case .whisperKit:
            return try await transcribeWithWhisper(audioPath: audioPath, profile: profile)
        }
    }

    private func transcribeWithWhisper(audioPath: String, profile: PerformanceProfile) async throws -> (segments: [TranscriptionSegment], fullText: String) {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            temperature: 0.0,                   // Greedy decoding = fastest
            temperatureFallbackCount: profile.temperatureFallbackCount,
            usePrefillPrompt: true,              // Skip predicting task/language tokens
            usePrefillCache: true,               // Pre-populate KV cache
            detectLanguage: true,                // Keep multilingual audio in its source language
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
        logger.notice("[WhisperKit] Transcription completed in \(String(format: "%.1f", elapsed))s, \(results.count) result(s), profile=\(profile.rawValue)")

        // Collect segments from all result chunks
        var allSegments: [TranscriptionSegment] = []
        allSegments.reserveCapacity(results.reduce(into: 0) { $0 += $1.segments.count })
        for result in results {
            for seg in result.segments {
                let cleaned = Self.cleanWhisperText(seg.text)
                guard !cleaned.isEmpty else { continue }

                // Collect word-level timings
                var words: [TranscriptionWord] = []
                if let wordTimings = seg.words {
                    words.reserveCapacity(wordTimings.count)
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

#if canImport(Speech)
    @available(macOS 26.0, *)
    private func prepareAppleSpeech() async {
        guard SpeechTranscriber.isAvailable else {
            updateAppleState(.error("Apple Speech transcription is not available on this Mac."))
            return
        }

        do {
            let locale = try await supportedAppleLocale()
            let localeIdentifier = locale.identifier
            let stateName = Self.appleStateName(for: locale)

            if appleModelState.isReady, preparedAppleLocaleIdentifier == localeIdentifier {
                updateAppleState(.loaded(stateName))
                return
            }

            updateAppleState(.loading)

            let reserved = try await AssetInventory.reserve(locale: locale)
            if reserved {
                logger.notice("[AppleSpeech] Reserved locale \(localeIdentifier)")
            }
            reservedAppleLocaleIdentifier = localeIdentifier

            let transcriber = makeAppleTranscriber(locale: locale, profile: .fast)
            let status = await AssetInventory.status(forModules: [transcriber])

            switch status {
            case .unsupported:
                preparedAppleLocaleIdentifier = nil
                updateAppleState(.error("Apple Speech does not support \(Self.displayName(for: locale))."))
            case .installed:
                preparedAppleLocaleIdentifier = localeIdentifier
                updateAppleState(.loaded(stateName))
            case .supported, .downloading:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    updateAppleState(.downloading(request.progress.fractionCompleted))

                    let progressTask = Task { [weak self] in
                        while !Task.isCancelled {
                            let progress = request.progress.fractionCompleted
                            await MainActor.run {
                                self?.updateAppleState(.downloading(progress))
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }

                    do {
                        try await request.downloadAndInstall()
                    } catch {
                        progressTask.cancel()
                        _ = await progressTask.result
                        throw error
                    }

                    progressTask.cancel()
                    _ = await progressTask.result
                }

                preparedAppleLocaleIdentifier = localeIdentifier
                updateAppleState(.loaded(stateName))
            @unknown default:
                preparedAppleLocaleIdentifier = nil
                updateAppleState(.error("Apple Speech returned an unknown asset state."))
            }
        } catch {
            preparedAppleLocaleIdentifier = nil
            updateAppleState(.error(Self.transcriptionErrorMessage(from: error)))
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWithAppleSpeech(audioPath: String, profile: PerformanceProfile) async throws -> (segments: [TranscriptionSegment], fullText: String) {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.backendUnavailable("Apple Speech transcription is not available on this Mac.")
        }

        let locale = try await supportedAppleLocale()
        let localeIdentifier = locale.identifier
        if !appleModelState.isReady || preparedAppleLocaleIdentifier != localeIdentifier {
            await prepareAppleSpeech()
        }

        guard appleModelState.isReady else {
            throw TranscriptionError.backendUnavailable(readinessErrorDescription)
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Self.duration(of: audioFile)
        let transcriber = makeAppleTranscriber(locale: locale, profile: profile)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )

        let resultsTask = Task { [weak self] () throws -> [TranscriptionSegment] in
            var segments: [TranscriptionSegment] = []

            for try await result in transcriber.results {
                let newSegments = Self.appleSegments(from: result)
                segments.append(contentsOf: newSegments)

                if duration > 0 {
                    let finalizedSeconds = CMTimeGetSeconds(result.resultsFinalizationTime)
                    let progress = min(0.95, max(0, finalizedSeconds / duration))
                    await MainActor.run {
                        self?.transcriptionProgress = progress
                    }
                }
            }

            return segments
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                transcriptionProgress = 0.98
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            var segments = try await resultsTask.value
            segments.sort { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }

            let fullText = segments.map(\.text).joined(separator: " ")
            logger.notice("[AppleSpeech] Transcription completed with \(segments.count) segment(s), locale=\(localeIdentifier)")
            return (segments, fullText)
        } catch {
            resultsTask.cancel()
            throw TranscriptionError.transcriptionFailed(Self.transcriptionErrorMessage(from: error))
        }
    }

    @available(macOS 26.0, *)
    private func makeAppleTranscriber(locale: Locale, profile: PerformanceProfile) -> SpeechTranscriber {
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = switch profile {
        case .fast:
            [.fastResults]
        case .accurate:
            []
        }

        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )
    }

    @available(macOS 26.0, *)
    private func supportedAppleLocale() async throws -> Locale {
        let requestedLocale: Locale
        if appleLocalePreference == Self.systemLocalePreferenceValue {
            requestedLocale = .autoupdatingCurrent
        } else {
            requestedLocale = Locale(identifier: appleLocalePreference)
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(Self.unsupportedAppleLocaleMessage(for: requestedLocale))
        }
        return locale
    }

    @available(macOS 26.0, *)
    private func normalizeAppleLocalePreference(using supportedLocales: [Locale]) async {
        guard appleLocalePreference != Self.systemLocalePreferenceValue else { return }

        if supportedLocales.contains(where: { $0.identifier == appleLocalePreference }) {
            return
        }

        let requestedLocale = Locale(identifier: appleLocalePreference)
        if let equivalentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            appleLocalePreference = equivalentLocale.identifier
        } else {
            appleLocalePreference = Self.systemLocalePreferenceValue
        }

        UserDefaults.standard.set(appleLocalePreference, forKey: Self.appleLocalePreferenceDefaultsKey)
    }

    private func releaseAppleLocaleReservation() async {
        guard let reservedAppleLocaleIdentifier else { return }
#if canImport(Speech)
        if #available(macOS 26.0, *) {
            await AssetInventory.release(reservedLocale: Locale(identifier: reservedAppleLocaleIdentifier))
            logger.notice("[AppleSpeech] Released locale \(reservedAppleLocaleIdentifier)")
        }
#endif
        self.reservedAppleLocaleIdentifier = nil
    }

    @available(macOS 26.0, *)
    private static func appleSegments(from result: SpeechTranscriber.Result) -> [TranscriptionSegment] {
        let text = cleanAppleText(String(result.text.characters))
        guard !text.isEmpty else { return [] }

        let fallbackRange = result.range
        var words: [TranscriptionWord] = []

        for run in result.text.runs {
            let runText = String(result.text[run.range].characters)
            let trimmedRunText = cleanAppleText(runText)
            guard !trimmedRunText.isEmpty else { continue }

            let timeRange = run[keyPath: \.audioTimeRange] ?? fallbackRange
            words.append(contentsOf: evenlyTimedWords(from: trimmedRunText, in: timeRange))
        }

        let segmentStart = words.first?.startTime ?? CMTimeGetSeconds(fallbackRange.start)
        let segmentEnd: TimeInterval
        if let lastWord = words.last {
            segmentEnd = lastWord.endTime
        } else {
            segmentEnd = CMTimeGetSeconds(fallbackRange.start + fallbackRange.duration)
        }

        return [
            TranscriptionSegment(
                startTime: max(0, segmentStart),
                endTime: max(segmentStart, segmentEnd),
                text: text,
                words: words
            )
        ]
    }

    private static func evenlyTimedWords(from text: String, in timeRange: CMTimeRange) -> [TranscriptionWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let start = CMTimeGetSeconds(timeRange.start)
        let duration = max(CMTimeGetSeconds(timeRange.duration), 0.01)
        let sliceDuration = duration / Double(tokens.count)

        return tokens.enumerated().map { index, token in
            let wordStart = start + (sliceDuration * Double(index))
            let isLast = index == tokens.count - 1
            let wordEnd = isLast ? (start + duration) : (wordStart + sliceDuration)
            return TranscriptionWord(
                word: token,
                startTime: max(0, wordStart),
                endTime: max(wordStart, wordEnd)
            )
        }
    }

    private static func cleanAppleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func duration(of audioFile: AVAudioFile) -> TimeInterval {
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audioFile.length) / sampleRate
    }

    private static func appleStateName(for locale: Locale) -> String {
        "Apple Speech (\(displayName(for: locale)))"
    }

    static func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func unsupportedAppleLocaleMessage(for requestedLocale: Locale) -> String {
        "Apple Speech does not support \(displayName(for: requestedLocale)) on this Mac."
    }
#endif

    private func updateWhisperState(_ state: ModelState) {
        whisperModelState = state
        if selectedBackend == .whisperKit {
            modelState = state
        }
    }

    private func updateAppleState(_ state: ModelState) {
        appleModelState = state
        if selectedBackend == .appleSpeech {
            modelState = state
        }
    }

    private func syncActiveState() {
        modelState = state(for: selectedBackend)
    }

    private func state(for backend: Backend) -> ModelState {
        switch backend {
        case .appleSpeech:
            return appleModelState
        case .whisperKit:
            return whisperModelState
        }
    }

    private static func transcriptionErrorMessage(from error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

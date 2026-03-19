import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class TranscriptionViewModel {

    enum ImportState: Equatable {
        case fetchingYouTubeTranscript
        case downloadingYouTube(Double)
        case extractingAudio
        case transcribing(Double)
        case diarizing
        case saving
    }

    enum YouTubeImportMode: String, CaseIterable, Identifiable {
        case transcriptOnly
        case withAudioPlayback

        var id: Self { self }

        var title: String {
            switch self {
            case .transcriptOnly:
                return "Transcript Only"
            case .withAudioPlayback:
                return "With Audio Playback"
            }
        }

        var detail: String {
            switch self {
            case .transcriptOnly:
                return "Fastest path. Imports captions only and skips the audio download."
            case .withAudioPlayback:
                return "Downloads audio so playback works. Falls back to Whisper if captions are unavailable."
            }
        }
    }

    struct ImportJob: Identifiable {
        let id: UUID
        var title: String
        var state: ImportState
        var task: Task<Void, Never>?
    }

    private(set) var importJobs: [ImportJob] = []
    var latestError: String?
    var selectedRecord: TranscriptionRecord?

    private let transcriptionService: TranscriptionService
    private let audioExtractionService: AudioExtractionService
    private let diarizationService: DiarizationService
    private let youTubeService: YouTubeService
    private let captionService: YouTubeCaptionService

    init(transcriptionService: TranscriptionService, audioExtractionService: AudioExtractionService, diarizationService: DiarizationService, youTubeService: YouTubeService, captionService: YouTubeCaptionService = YouTubeCaptionService()) {
        self.transcriptionService = transcriptionService
        self.audioExtractionService = audioExtractionService
        self.diarizationService = diarizationService
        self.youTubeService = youTubeService
        self.captionService = captionService
    }

    var isImporting: Bool {
        !importJobs.isEmpty
    }

    /// Import a file: validate → extract audio (if video) → transcribe → save
    func importFile(_ url: URL, modelContext: ModelContext) {
        guard AudioExtractionService.isSupported(url) else {
            latestError = "Unsupported file format: \(url.pathExtension)"
            return
        }

        guard transcriptionService.modelState.isReady else {
            latestError = "Whisper model is not loaded. Please load a model in Settings first."
            return
        }

        let jobID = UUID()
        let job = ImportJob(id: jobID, title: url.lastPathComponent, state: .extractingAudio)
        importJobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }

            let securityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if securityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                // Step 1: Extract audio if needed
                let audioURL = try await self.audioExtractionService.extractAudio(from: url)

                // Step 2: Get duration
                let duration = try await self.audioExtractionService.getDuration(of: url)

                // Step 3: Transcribe
                self.updateJob(jobID, state: .transcribing(0))
                var result = try await self.transcriptionService.transcribe(audioPath: audioURL.path)

                // Step 4: Speaker diarization
                if self.diarizationService.modelState.isReady {
                    self.updateJob(jobID, state: .diarizing)
                    let speakerSegments = try await self.diarizationService.diarize(audioPath: audioURL.path)
                    if !speakerSegments.isEmpty {
                        result.segments = Self.assignSpeakerLabels(
                            segments: result.segments,
                            speakerSegments: speakerSegments
                        )
                    }
                }

                // Step 5: Copy file into sandbox for playback access
                self.updateJob(jobID, state: .saving)
                let localAudioPath = try self.copyFileToSandbox(url)

                // Step 6: Save to SwiftData
                let record = TranscriptionRecord(
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    duration: duration,
                    segments: result.segments,
                    fullText: result.fullText,
                    localAudioPath: localAudioPath
                )
                modelContext.insert(record)
                try modelContext.save()

                self.removeJob(jobID)
                if self.selectedRecord == nil {
                    self.selectedRecord = record
                }

                // Clean up temp file if we extracted audio
                if audioURL != url {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            } catch {
                self.removeJob(jobID)
                self.latestError = error.localizedDescription
            }
        }

        // Store the task handle on the job
        if let index = importJobs.firstIndex(where: { $0.id == jobID }) {
            importJobs[index].task = task
        }
    }

    /// Import a YouTube URL using either transcript-only or audio-backed flow.
    func importYouTubeURL(_ url: URL, mode: YouTubeImportMode, modelContext: ModelContext) {
        let normalizedURL = YouTubeService.normalizedYouTubeURL(url.absoluteString) ?? url
        let jobID = UUID()
        let initialState: ImportState = switch mode {
        case .transcriptOnly:
            .fetchingYouTubeTranscript
        case .withAudioPlayback:
            .downloadingYouTube(0)
        }
        let job = ImportJob(id: jobID, title: "YouTube video", state: initialState)
        importJobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                let audioURL: URL?
                let duration: TimeInterval
                let title: String
                var segments: [TranscriptionSegment]
                var fullText: String

                switch mode {
                case .transcriptOnly:
                    guard let captions = await self.fetchCaptionsWithTimeout(from: normalizedURL) else {
                        throw NSError(
                            domain: "YouTubeImport",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey: "No transcript was available for this video. Re-import with audio playback if you want to download the audio and transcribe it."
                            ]
                        )
                    }

                    title = captions.title ?? "YouTube Video"
                    duration = captions.duration ?? Self.captionDuration(captions)
                    segments = captions.segments
                    fullText = captions.fullText
                    audioURL = nil
                case .withAudioPlayback:
                    let progressTask = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(100))
                            let progress = self.youTubeService.downloadProgress
                            if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }),
                               case .downloadingYouTube = self.importJobs[idx].state {
                                self.importJobs[idx].state = .downloadingYouTube(progress)
                            }
                        }
                    }
                    defer { progressTask.cancel() }

                    async let captionResult = self.fetchCaptionsWithTimeout(from: normalizedURL)

                    let rawAudioURL: URL
                    let downloadedTitle: String
                    do {
                        let result = try await self.youTubeService.downloadAudio(from: normalizedURL)
                        rawAudioURL = result.audioURL
                        downloadedTitle = result.title
                    } catch {
                        throw NSError(
                            domain: "YouTubeImport",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: error.localizedDescription
                            ]
                        )
                    }

                    title = downloadedTitle.isEmpty ? "YouTube Video" : downloadedTitle

                    // Step 2: Re-export through AVFoundation to normalize the audio format
                    self.updateJob(jobID, state: .extractingAudio)
                    let normalizedAudioURL = try await self.audioExtractionService.reExportAudio(from: rawAudioURL)
                    try? FileManager.default.removeItem(at: rawAudioURL)
                    audioURL = normalizedAudioURL

                    // Step 3: Get duration
                    duration = try await self.audioExtractionService.getDuration(of: normalizedAudioURL)

                    if let captions = await captionResult {
                        segments = captions.segments
                        fullText = captions.fullText
                    } else {
                        guard self.transcriptionService.modelState.isReady else {
                            self.removeJob(jobID)
                            self.latestError = "No captions available and Whisper model is not loaded. Please load a model in Settings first."
                            try? FileManager.default.removeItem(at: normalizedAudioURL)
                            return
                        }
                        self.updateJob(jobID, state: .transcribing(0))
                        let result = try await self.transcriptionService.transcribe(audioPath: normalizedAudioURL.path)
                        segments = result.segments
                        fullText = result.fullText
                    }
                }

                if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }) {
                    self.importJobs[idx].title = title
                }

                // Step 5: Speaker diarization
                if let audioURL, self.diarizationService.modelState.isReady {
                    self.updateJob(jobID, state: .diarizing)
                    let speakerSegments = try await self.diarizationService.diarize(audioPath: audioURL.path)
                    if !speakerSegments.isEmpty {
                        segments = Self.assignSpeakerLabels(
                            segments: segments,
                            speakerSegments: speakerSegments
                        )
                    }
                }

                // Step 6: Copy audio into sandbox for playback
                self.updateJob(jobID, state: .saving)
                let localAudioPath = try audioURL.map(self.copyFileToSandbox)

                // Step 7: Save to SwiftData
                let record = TranscriptionRecord(
                    fileName: title,
                    fileURL: normalizedURL,
                    duration: duration,
                    segments: segments,
                    fullText: fullText,
                    localAudioPath: localAudioPath
                )
                modelContext.insert(record)
                try modelContext.save()

                self.removeJob(jobID)
                if self.selectedRecord == nil {
                    self.selectedRecord = record
                }

                // Clean up temp file
                if let audioURL {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            } catch {
                if Task.isCancelled { return }
                self.removeJob(jobID)
                self.latestError = error.localizedDescription
            }
        }

        if let index = importJobs.firstIndex(where: { $0.id == jobID }) {
            importJobs[index].task = task
        }
    }

    func clearError() {
        latestError = nil
    }

    func deleteRecord(_ record: TranscriptionRecord, modelContext: ModelContext) {
        // Delete the local audio copy
        if let audioURL = record.localAudioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        if selectedRecord?.id == record.id {
            selectedRecord = nil
        }
        modelContext.delete(record)
        try? modelContext.save()
    }

    // MARK: - Job Helpers

    private func updateJob(_ id: UUID, state: ImportState) {
        if let index = importJobs.firstIndex(where: { $0.id == id }) {
            importJobs[index].state = state
        }
    }

    private func removeJob(_ id: UUID) {
        importJobs.removeAll { $0.id == id }
    }

    /// Don't let caption fetches block YouTube import if YouTube's caption endpoint stalls.
    private func fetchCaptionsWithTimeout(from url: URL, timeout: Duration = .seconds(6)) async -> YouTubeCaptionResult? {
        await withTaskGroup(of: YouTubeCaptionResult?.self) { group in
            group.addTask { [captionService] in
                await captionService.fetchCaptions(from: url)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func captionDuration(_ captions: YouTubeCaptionResult) -> TimeInterval {
        captions.segments.map(\.endTime).max() ?? 0
    }

    // MARK: - Speaker Label Merge

    /// Assign speaker labels to segments and words by finding the diarization speaker
    /// with the greatest time overlap for each time range.
    private static func assignSpeakerLabels(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]
    ) -> [TranscriptionSegment] {
        let diarizationSegments = speakerSegments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !diarizationSegments.isEmpty else { return segments }

        // Build a friendly label map: "speaker_0" → "Speaker 1"
        var labelMap: [String: String] = [:]
        var nextIndex = 1
        for seg in diarizationSegments {
            if labelMap[seg.speakerId] == nil {
                labelMap[seg.speakerId] = "Speaker \(nextIndex)"
                nextIndex += 1
            }
        }

        var previousSegmentLabel: String?
        return segments.map { segment in
            var updated = segment
            updated.speakerLabel = bestSpeaker(
                start: segment.startTime,
                end: segment.endTime,
                speakerSegments: diarizationSegments,
                labelMap: labelMap,
                fallbackLabel: previousSegmentLabel
            )
            previousSegmentLabel = updated.speakerLabel ?? previousSegmentLabel

            var previousWordLabel = updated.speakerLabel
            updated.words = segment.words.map { word in
                var w = word
                let wordEnd = word.endTime > word.startTime ? word.endTime : word.startTime + 0.12
                w.speakerLabel = bestSpeaker(
                    start: word.startTime,
                    end: wordEnd,
                    speakerSegments: diarizationSegments,
                    labelMap: labelMap,
                    fallbackLabel: previousWordLabel
                )
                previousWordLabel = w.speakerLabel ?? previousWordLabel
                return w
            }
            return updated
        }
    }

    /// Find the speaker with the greatest overlap for a given time range.
    /// Falls back to the nearest diarization segment if there is no overlap.
    private static func bestSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        speakerSegments: [SpeakerSegment],
        labelMap: [String: String],
        fallbackLabel: String?
    ) -> String? {
        let overlapTolerance: TimeInterval = 0.12
        let adjustedEnd = max(end, start + 0.01)

        // First try: find speaker with the most overlap
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for seg in speakerSegments {
            let overlapStart = max(start - overlapTolerance, seg.start)
            let overlapEnd = min(adjustedEnd + overlapTolerance, seg.end)
            let overlap = overlapEnd - overlapStart
            if overlap > 0 {
                overlapBySpeaker[seg.speakerId, default: 0] += overlap
            }
        }
        if let best = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return labelMap[best.key]
        }

        // Fallback: find the nearest diarization segment by time distance
        let midpoint = (start + adjustedEnd) / 2
        let nearest = speakerSegments.min { a, b in
            let distA = distance(from: midpoint, to: a)
            let distB = distance(from: midpoint, to: b)
            return distA < distB
        }
        guard let nearest else { return fallbackLabel }
        return labelMap[nearest.speakerId] ?? fallbackLabel
    }

    private static func distance(from point: TimeInterval, to segment: SpeakerSegment) -> TimeInterval {
        if point < segment.start {
            return segment.start - point
        }
        if point > segment.end {
            return point - segment.end
        }
        return 0
    }

    /// Copy the imported file into the app's sandbox container
    private func copyFileToSandbox(_ url: URL) throws -> String {
        let storageDir = TranscriptionRecord.audioStorageDirectory
        let ext = url.pathExtension
        let destURL = storageDir.appending(path: "\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: destURL)
        return destURL.path
    }
}

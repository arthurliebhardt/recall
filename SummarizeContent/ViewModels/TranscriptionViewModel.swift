import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class TranscriptionViewModel {

    enum ImportState: Equatable {
        case downloadingYouTube(Double)
        case extractingAudio
        case transcribing(Double)
        case diarizing
        case saving
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
    private let sapVideoService: SAPVideoService

    init(transcriptionService: TranscriptionService, audioExtractionService: AudioExtractionService, diarizationService: DiarizationService, youTubeService: YouTubeService, captionService: YouTubeCaptionService = YouTubeCaptionService(), sapVideoService: SAPVideoService) {
        self.transcriptionService = transcriptionService
        self.audioExtractionService = audioExtractionService
        self.diarizationService = diarizationService
        self.youTubeService = youTubeService
        self.captionService = captionService
        self.sapVideoService = sapVideoService
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

    /// Import audio from a YouTube URL: download + fetch captions in parallel → use captions or fall back to Whisper → diarize → save
    func importYouTubeURL(_ url: URL, modelContext: ModelContext) {
        let normalizedURL = YouTubeService.normalizedYouTubeURL(url.absoluteString) ?? url
        let jobID = UUID()
        let job = ImportJob(id: jobID, title: "YouTube video", state: .downloadingYouTube(0))
        importJobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                // Step 1: Download audio and fetch captions in parallel
                let progressTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(100))
                        let progress = await self.youTubeService.downloadProgress
                        if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }),
                           case .downloadingYouTube = self.importJobs[idx].state {
                            self.importJobs[idx].state = .downloadingYouTube(progress)
                        }
                    }
                }
                defer { progressTask.cancel() }

                async let captionResult = self.fetchCaptionsWithTimeout(from: normalizedURL)
                async let audioResult = self.youTubeService.downloadAudio(from: normalizedURL)

                let (rawAudioURL, title) = try await audioResult
                let captions = await captionResult

                // Update the job title now that we know it
                if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }) {
                    self.importJobs[idx].title = title
                }

                // Step 2: Re-export through AVFoundation to normalize the audio format
                self.updateJob(jobID, state: .extractingAudio)
                let audioURL = try await self.audioExtractionService.reExportAudio(from: rawAudioURL)
                try? FileManager.default.removeItem(at: rawAudioURL)

                // Step 3: Get duration
                let duration = try await self.audioExtractionService.getDuration(of: audioURL)

                // Step 4: Get transcript — use captions (fast path) or fall back to Whisper (slow path)
                var segments: [TranscriptionSegment]
                var fullText: String

                if let captions {
                    segments = captions.segments
                    fullText = captions.fullText
                } else {
                    guard self.transcriptionService.modelState.isReady else {
                        self.removeJob(jobID)
                        self.latestError = "No captions available and Whisper model is not loaded. Please load a model in Settings first."
                        try? FileManager.default.removeItem(at: audioURL)
                        return
                    }
                    self.updateJob(jobID, state: .transcribing(0))
                    let result = try await self.transcriptionService.transcribe(audioPath: audioURL.path)
                    segments = result.segments
                    fullText = result.fullText
                }

                // Step 5: Speaker diarization
                if self.diarizationService.modelState.isReady {
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
                let localAudioPath = try self.copyFileToSandbox(audioURL)

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
                try? FileManager.default.removeItem(at: audioURL)
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

    /// Import audio from an SAP Video URL: download via yt-dlp with Chrome cookies → normalize → Whisper transcribe → diarize → save
    func importSAPVideoURL(_ url: URL, modelContext: ModelContext) {
        guard let normalizedURL = SAPVideoService.normalizedSAPVideoURL(url.absoluteString) else {
            latestError = SAPVideoService.SAPVideoError.invalidURL.localizedDescription
            return
        }

        guard transcriptionService.modelState.isReady else {
            latestError = "Whisper model is not loaded. SAP videos have no captions, so a Whisper model is required. Please load a model in Settings first."
            return
        }

        let jobID = UUID()
        let job = ImportJob(id: jobID, title: "SAP Video", state: .downloadingYouTube(0))
        importJobs.append(job)

        let task = Task { [weak self] in
            guard let self else { return }

            do {
                // Step 1: Download audio via yt-dlp
                let progressTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(100))
                        let progress = await self.sapVideoService.downloadProgress
                        if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }),
                           case .downloadingYouTube = self.importJobs[idx].state {
                            self.importJobs[idx].state = .downloadingYouTube(progress)
                        }
                    }
                }
                defer { progressTask.cancel() }

                let (rawAudioURL, title) = try await self.sapVideoService.downloadAudio(from: normalizedURL)

                // Update the job title now that we know it
                if let idx = self.importJobs.firstIndex(where: { $0.id == jobID }) {
                    self.importJobs[idx].title = title
                }

                // Step 2: Re-export through AVFoundation to normalize the audio format
                self.updateJob(jobID, state: .extractingAudio)
                let audioURL = try await self.audioExtractionService.reExportAudio(from: rawAudioURL)
                try? FileManager.default.removeItem(at: rawAudioURL)

                // Step 3: Get duration
                let duration = try await self.audioExtractionService.getDuration(of: audioURL)

                // Step 4: Transcribe with Whisper (SAP videos have no captions)
                self.updateJob(jobID, state: .transcribing(0))
                let result = try await self.transcriptionService.transcribe(audioPath: audioURL.path)
                var segments = result.segments
                let fullText = result.fullText

                // Step 5: Speaker diarization
                if self.diarizationService.modelState.isReady {
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
                let localAudioPath = try self.copyFileToSandbox(audioURL)

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
                try? FileManager.default.removeItem(at: audioURL)
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

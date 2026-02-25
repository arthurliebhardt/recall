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

    /// Import audio from a YouTube URL: download + fetch captions in parallel → use captions or fall back to Whisper → diarize → save
    func importYouTubeURL(_ url: URL, modelContext: ModelContext) {
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

                let captionService = self.captionService
                async let captionResult = captionService.fetchCaptions(from: url)
                async let audioResult = self.youTubeService.downloadAudio(from: url)

                let captions = await captionResult
                let (rawAudioURL, title) = try await audioResult
                progressTask.cancel()

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
                    fileURL: url,
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

    // MARK: - Speaker Label Merge

    /// Assign speaker labels to segments and words by finding the diarization speaker
    /// with the greatest time overlap for each time range.
    private static func assignSpeakerLabels(
        segments: [TranscriptionSegment],
        speakerSegments: [SpeakerSegment]
    ) -> [TranscriptionSegment] {
        // Build a friendly label map: "speaker_0" → "Speaker 1"
        var labelMap: [String: String] = [:]
        var nextIndex = 1
        for seg in speakerSegments {
            if labelMap[seg.speakerId] == nil {
                labelMap[seg.speakerId] = "Speaker \(nextIndex)"
                nextIndex += 1
            }
        }

        return segments.map { segment in
            var updated = segment
            updated.speakerLabel = bestSpeaker(
                start: segment.startTime,
                end: segment.endTime,
                speakerSegments: speakerSegments,
                labelMap: labelMap
            )
            updated.words = segment.words.map { word in
                var w = word
                w.speakerLabel = bestSpeaker(
                    start: word.startTime,
                    end: word.endTime,
                    speakerSegments: speakerSegments,
                    labelMap: labelMap
                )
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
        labelMap: [String: String]
    ) -> String? {
        // First try: find speaker with the most overlap
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for seg in speakerSegments {
            let overlapStart = max(start, seg.start)
            let overlapEnd = min(end, seg.end)
            let overlap = overlapEnd - overlapStart
            if overlap > 0 {
                overlapBySpeaker[seg.speakerId, default: 0] += overlap
            }
        }
        if let best = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return labelMap[best.key]
        }

        // Fallback: find the nearest diarization segment by time distance
        let midpoint = (start + end) / 2
        let nearest = speakerSegments.min { a, b in
            let distA = min(abs(a.start - midpoint), abs(a.end - midpoint))
            let distB = min(abs(b.start - midpoint), abs(b.end - midpoint))
            return distA < distB
        }
        guard let nearest else { return nil }
        return labelMap[nearest.speakerId]
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

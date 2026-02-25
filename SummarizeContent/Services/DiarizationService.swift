import Foundation
import os
import FluidAudio

private let logger = Logger(subsystem: "com.summarizecontent.app", category: "Diarization")

struct SpeakerSegment {
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval
}

@Observable
@MainActor
final class DiarizationService {

    enum ModelState: Equatable {
        case notLoaded
        case downloading
        case loading
        case loaded
        case error(String)

        var isReady: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    private(set) var modelState: ModelState = .notLoaded

    private var manager: OfflineDiarizerManager?

    // MARK: - Model Management

    func prepareModels() async {
        modelState = .downloading
        logger.notice("[Diarization] Preparing models...")

        do {
            // Build a tuned config for better speaker separation:
            // - clusteringThreshold 0.40: cosine similarity; lower = more likely to split
            //   into separate speakers (0.72 merged all, 0.55 still merged on podcasts)
            // - stepRatio 0.1: finer sliding window overlap for better time resolution on
            //   speaker transitions (default 0.2)
            // - minDurationOn/Off 0.1: detect shorter speaker turns (default varies)
            var config = OfflineDiarizerConfig(clusteringThreshold: 0.40)
            config.segmentation.stepRatio = 0.1
            config.segmentation.minDurationOn = 0.1
            config.segmentation.minDurationOff = 0.1
            config.embedding.minSegmentDurationSeconds = 0.5
            config.postProcessing.minGapDurationSeconds = 0.1
            let om = OfflineDiarizerManager(config: config)
            try await om.prepareModels()
            manager = om

            modelState = .loaded
            logger.notice("[Diarization] Models ready")
        } catch {
            logger.error("[Diarization] Failed to prepare models: \(error)")
            modelState = .error(error.localizedDescription)
        }
    }

    // MARK: - Diarization

    func diarize(audioPath: String) async throws -> [SpeakerSegment] {
        guard modelState.isReady, let manager else { return [] }

        logger.notice("[Diarization] Starting diarization for: \(audioPath)")
        let startTime = CFAbsoluteTimeGetCurrent()

        let samples = try AudioConverter().resampleAudioFile(path: audioPath)
        logger.notice("[Diarization] Converted audio: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        let result = try await manager.process(audio: samples)

        let speakerIds = Set(result.segments.map(\.speakerId))
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.notice("[Diarization] Completed in \(String(format: "%.1f", elapsed))s, \(result.segments.count) segments, \(speakerIds.count) speakers: \(Array(speakerIds).sorted())")

        if let timings = result.timings {
            logger.notice("[Diarization] Timings — segmentation: \(String(format: "%.2f", timings.segmentationSeconds))s, embedding: \(String(format: "%.2f", timings.embeddingExtractionSeconds))s, clustering: \(String(format: "%.2f", timings.speakerClusteringSeconds))s")
        }

        return result.segments.map { segment in
            SpeakerSegment(
                speakerId: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }
    }
}

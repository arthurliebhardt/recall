import Foundation
import os
import FluidAudio
import AVFoundation

private let logger = Logger(subsystem: "com.summarizecontent.app", category: "Diarization")

struct SpeakerSegment {
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval
}

@Observable
@MainActor
final class DiarizationService {
    private static let primaryClusteringThreshold = 0.7045655
    private static let fallbackClusteringThresholds: [Double] = [0.80, 0.88, 0.93, 0.96]

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
    private var fallbackManagers: [Double: OfflineDiarizerManager] = [:]

    private struct CandidateSummary {
        let result: DiarizationResult
        let threshold: Double
        let rawSpeakerCount: Int
        let effectiveSpeakerCount: Int
        let fragmentationScore: Int
        let minSpeakerDuration: TimeInterval
    }

    // MARK: - Model Management

    func prepareModels() async {
        modelState = .downloading
        Self.writeDebugLog("Debug log path: \(Self.debugLogURL.path)")
        logger.notice("[Diarization] Preparing models... (debug log: \(Self.debugLogURL.path))")

        do {
            let om = OfflineDiarizerManager(
                config: Self.makeConfig(clusteringThreshold: Self.primaryClusteringThreshold)
            )
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
        guard modelState.isReady, let manager else {
            Self.writeDebugLog("Diarization skipped: model not ready or manager nil")
            return []
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        Self.writeDebugLog("Starting diarization for: \(audioPath)")
        let audioURL = URL(fileURLWithPath: audioPath)
        let durationSec = Self.audioDurationSeconds(at: audioURL) ?? 0.0

        if durationSec > 0 {
            Self.writeDebugLog("Audio duration: \(String(format: "%.1f", durationSec))s")
        } else {
            Self.writeDebugLog("Audio duration unavailable")
        }

        var selectedThreshold = Self.primaryClusteringThreshold
        var result = try await manager.process(audioURL)
        var speakerIds = Set(result.segments.map(\.speakerId))
        var bestCandidate = summarizeCandidate(
            result: result,
            threshold: selectedThreshold,
            durationSec: durationSec
        )

        if shouldRunFallbackPass(
            durationSec: durationSec,
            segmentCount: result.segments.count,
            effectiveSpeakerCount: bestCandidate.effectiveSpeakerCount
        ) {
            Self.writeDebugLog(
                "Fallback diarization enabled: initial pass returned rawSpeakers=\(speakerIds.count), effectiveSpeakers=\(bestCandidate.effectiveSpeakerCount); trying stricter thresholds \(Self.fallbackClusteringThresholds)"
            )
            for threshold in Self.fallbackClusteringThresholds {
                do {
                    let fallbackManager = try await diarizerManager(for: threshold)
                    let candidate = try await fallbackManager.process(audioURL)
                    let summary = summarizeCandidate(
                        result: candidate,
                        threshold: threshold,
                        durationSec: durationSec
                    )
                    Self.writeDebugLog(
                        "Fallback pass threshold=\(String(format: "%.2f", threshold)) produced rawSpeakers=\(summary.rawSpeakerCount), effectiveSpeakers=\(summary.effectiveSpeakerCount), segments=\(candidate.segments.count), minSpeakerDur=\(String(format: "%.1f", summary.minSpeakerDuration))s"
                    )

                    if isBetterCandidate(summary, than: bestCandidate) {
                        bestCandidate = summary
                    }
                } catch {
                    logger.warning("[Diarization] Fallback threshold \(threshold) failed: \(error)")
                    Self.writeDebugLog(
                        "Fallback pass threshold=\(String(format: "%.2f", threshold)) failed: \(error.localizedDescription)"
                    )
                }
            }

            result = bestCandidate.result
            selectedThreshold = bestCandidate.threshold
            speakerIds = Set(result.segments.map(\.speakerId))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Build detailed debug info
        var debug = "[Diarization] Completed in \(String(format: "%.1f", elapsed))s using threshold \(String(format: "%.2f", selectedThreshold))\n"
        debug += "  Total segments: \(result.segments.count)\n"
        debug += "  Unique speakers: \(speakerIds.count) — \(Array(speakerIds).sorted())\n"
        debug += "  Effective speakers: \(bestCandidate.effectiveSpeakerCount) (min speaker duration \(String(format: "%.1f", bestCandidate.minSpeakerDuration))s)\n"
        if let timings = result.timings {
            debug += "  Timings: seg=\(String(format: "%.2f", timings.segmentationSeconds))s emb=\(String(format: "%.2f", timings.embeddingExtractionSeconds))s clust=\(String(format: "%.2f", timings.speakerClusteringSeconds))s\n"
        }
        // Log first 20 segments with their speaker IDs
        debug += "  First segments:\n"
        for (i, seg) in result.segments.prefix(20).enumerated() {
            debug += "    [\(i)] \(String(format: "%.1f", seg.startTimeSeconds))-\(String(format: "%.1f", seg.endTimeSeconds))s speaker=\(seg.speakerId)\n"
        }
        if result.segments.count > 20 {
            debug += "    ... and \(result.segments.count - 20) more\n"
        }
        Self.writeDebugLog(debug)

        logger.notice("[Diarization] \(result.segments.count) segments, \(speakerIds.count) speakers: \(Array(speakerIds).sorted())")

        return result.segments.map { segment in
            SpeakerSegment(
                speakerId: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }
    }

    // MARK: - Debug Logging

    static let debugLogURL: URL = {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("diarization_debug.log")
    }()

    static func writeDebugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = debugLogURL.path
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    private static func makeConfig(clusteringThreshold: Double) -> OfflineDiarizerConfig {
        // FluidAudio expects clusteringThreshold in cosine-similarity space.
        // Higher threshold values make clustering stricter and reduce over-merging.
        OfflineDiarizerConfig(clusteringThreshold: clusteringThreshold)
    }

    private func diarizerManager(for clusteringThreshold: Double) async throws -> OfflineDiarizerManager {
        if clusteringThreshold == Self.primaryClusteringThreshold, let manager {
            return manager
        }
        if let cached = fallbackManagers[clusteringThreshold] {
            return cached
        }

        let fallbackManager = OfflineDiarizerManager(
            config: Self.makeConfig(clusteringThreshold: clusteringThreshold)
        )
        try await fallbackManager.prepareModels()
        fallbackManagers[clusteringThreshold] = fallbackManager
        return fallbackManager
    }

    private func shouldRunFallbackPass(
        durationSec: Double,
        segmentCount: Int,
        effectiveSpeakerCount: Int
    ) -> Bool {
        // Only retry with stricter clustering when the dominant outcome is still a single speaker.
        // Running the fallback on already-separated 2-speaker audio tends to fragment one person
        // into multiple labels (for example Speaker 2 / Speaker 3).
        durationSec >= 60.0 && segmentCount >= 3 && effectiveSpeakerCount <= 1
    }

    private static func audioDurationSeconds(at url: URL) -> Double? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.fileFormat.sampleRate
            guard sampleRate > 0 else { return nil }
            return Double(audioFile.length) / sampleRate
        } catch {
            return nil
        }
    }

    private func summarizeCandidate(
        result: DiarizationResult,
        threshold: Double,
        durationSec: Double
    ) -> CandidateSummary {
        let rawSpeakerCount = Set(result.segments.map(\.speakerId)).count
        let minSpeakerDuration = max(2.5, min(12.0, durationSec * 0.04))

        var speakerDurations: [String: TimeInterval] = [:]
        for segment in result.segments {
            let dur = max(0, TimeInterval(segment.endTimeSeconds - segment.startTimeSeconds))
            if dur > 0 {
                speakerDurations[segment.speakerId, default: 0] += dur
            }
        }

        let effectiveSpeakerCount = max(
            1,
            speakerDurations.values.filter { $0 >= minSpeakerDuration }.count
        )

        return CandidateSummary(
            result: result,
            threshold: threshold,
            rawSpeakerCount: rawSpeakerCount,
            effectiveSpeakerCount: effectiveSpeakerCount,
            fragmentationScore: max(0, rawSpeakerCount - effectiveSpeakerCount),
            minSpeakerDuration: minSpeakerDuration
        )
    }

    private func isBetterCandidate(
        _ lhs: CandidateSummary,
        than rhs: CandidateSummary
    ) -> Bool {
        if lhs.effectiveSpeakerCount != rhs.effectiveSpeakerCount {
            return lhs.effectiveSpeakerCount > rhs.effectiveSpeakerCount
        }
        if lhs.fragmentationScore != rhs.fragmentationScore {
            return lhs.fragmentationScore < rhs.fragmentationScore
        }
        if lhs.rawSpeakerCount != rhs.rawSpeakerCount {
            return lhs.rawSpeakerCount > rhs.rawSpeakerCount
        }
        return lhs.threshold < rhs.threshold
    }
}

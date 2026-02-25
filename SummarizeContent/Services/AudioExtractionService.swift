import AVFoundation
import Foundation

@Observable
final class AudioExtractionService {

    enum ExtractionError: LocalizedError {
        case unsupportedFormat
        case exportFailed(String)
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Unsupported file format."
            case .exportFailed(let reason):
                return "Audio export failed: \(reason)"
            case .noAudioTrack:
                return "No audio track found in the file."
            }
        }
    }

    static let supportedAudioExtensions = Set(["mp3", "wav", "m4a", "flac"])
    static let supportedVideoExtensions = Set(["mp4", "mov"])
    static let allSupportedExtensions = supportedAudioExtensions.union(supportedVideoExtensions)

    /// Returns true if the file is a video that needs audio extraction
    static func isVideo(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns true if the format is supported
    static func isSupported(_ url: URL) -> Bool {
        allSupportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Extract audio from a video file to a temporary .m4a file.
    /// For audio files, returns the original URL directly.
    func extractAudio(from url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()

        guard Self.allSupportedExtensions.contains(ext) else {
            throw ExtractionError.unsupportedFormat
        }

        // Audio files can be passed directly to WhisperKit
        if Self.supportedAudioExtensions.contains(ext) {
            return url
        }

        // Video files need audio extraction
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !audioTracks.isEmpty else {
            throw ExtractionError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractionError.exportFailed("Could not create export session.")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .failed:
            throw ExtractionError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw ExtractionError.exportFailed("Export was cancelled.")
        default:
            throw ExtractionError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)")
        }
    }

    /// Re-export any audio file through AVFoundation to produce a clean Apple M4A.
    /// Useful for normalizing audio from external sources (e.g. YouTube) that may use
    /// non-standard encoding profiles the diarization model struggles with.
    func reExportAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !audioTracks.isEmpty else {
            throw ExtractionError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractionError.exportFailed("Could not create export session.")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .failed:
            throw ExtractionError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw ExtractionError.exportFailed("Export was cancelled.")
        default:
            throw ExtractionError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)")
        }
    }

    /// Get the duration of an audio/video file in seconds.
    func getDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds
    }
}

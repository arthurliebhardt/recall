import Foundation
import YouTubeKit

@Observable
@MainActor
final class YouTubeService {

    enum YouTubeError: LocalizedError {
        case invalidURL
        case noAudioStream
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid YouTube URL. Please paste a valid youtube.com or youtu.be link."
            case .noAudioStream:
                return "Could not find an audio stream for this video."
            case .downloadFailed(let reason):
                return "Failed to download audio: \(reason)"
            }
        }
    }

    private(set) var downloadProgress: Double = 0

    /// Validate that a URL is a YouTube video URL
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"]
        guard youtubeHosts.contains(host) else { return false }

        if host.contains("youtu.be") {
            return !url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        } else {
            return url.absoluteString.contains("watch?") || url.path().contains("/shorts/")
        }
    }

    /// Download the best audio stream from a YouTube video.
    /// Returns the local file URL and the video title.
    func downloadAudio(from url: URL) async throws -> (audioURL: URL, title: String) {
        guard Self.isYouTubeURL(url) else {
            throw YouTubeError.invalidURL
        }

        downloadProgress = 0

        let video = YouTube(url: url, methods: [.local, .remote])

        // Get video title from metadata
        let metadata = try await video.metadata
        let title = metadata?.title ?? "YouTube Video"

        // Find a medium-quality m4a audio stream — balances download speed with
        // enough fidelity for speaker diarization to distinguish voices
        let streams = try await video.streams
        let m4aStreams = streams.filterAudioOnly().filter { $0.fileExtension == .m4a }
        let audioStream: YouTubeKit.Stream? = {
            let sorted = m4aStreams.sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            // Pick the middle stream for a good speed/quality balance
            if sorted.count >= 2 {
                return sorted[sorted.count / 2]
            }
            return sorted.first
        }() ?? streams.filterAudioOnly().lowestAudioBitrateStream()

        guard let stream = audioStream else {
            throw YouTubeError.noAudioStream
        }

        // Download to temp directory with progress tracking
        let ext = stream.fileExtension.rawValue
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        let progressDelegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        let (tempURL, _) = try await URLSession.shared.download(
            from: stream.url,
            delegate: progressDelegate
        )

        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        downloadProgress = 1.0

        return (audioURL: outputURL, title: title)
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // no-op, required for delegate conformance
    }

    func urlSession(
        _ session: URLSession,
        didCreateTask task: URLSessionTask
    ) {
        // KVO on the task's countOfBytesReceived
        let observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
        // Store observation to keep it alive for the task's lifetime
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
    }
}

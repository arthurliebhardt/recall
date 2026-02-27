import Foundation
import YouTubeKit

@Observable
@MainActor
final class YouTubeService {

    enum YouTubeError: LocalizedError {
        case invalidURL
        case noAudioStream
        case downloadFailed(String)
        case ytDlpNotFound

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid YouTube URL. Please paste a valid youtube.com or youtu.be link."
            case .noAudioStream:
                return "Could not find an audio stream for this video."
            case .downloadFailed(let reason):
                return "Failed to download audio: \(reason)"
            case .ytDlpNotFound:
                return "yt-dlp not found. Install it with: brew install yt-dlp"
            }
        }
    }

    private(set) var downloadProgress: Double = 0

    private static let youtubeHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "www.youtu.be"
    ]

    /// Parse and normalize pasted YouTube URLs. Accepts links with or without scheme.
    static func normalizedYouTubeURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let url = components.url else {
            return nil
        }

        guard isYouTubeURL(url) else { return nil }
        return url
    }

    /// Validate that a URL is a YouTube video URL
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              youtubeHosts.contains(host) else { return false }

        return extractVideoID(from: components) != nil
    }

    private static func extractVideoID(from components: URLComponents) -> String? {
        guard let host = components.host?.lowercased() else { return nil }

        if host.contains("youtu.be") {
            let id = components.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .first
                .map(String.init)
            return (id?.isEmpty == false) ? id : nil
        }

        let path = components.path
        if path.hasPrefix("/watch"),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !vParam.isEmpty {
            return vParam
        }

        for prefix in ["/shorts/", "/live/", "/embed/"] {
            if path.hasPrefix(prefix) {
                let suffix = String(path.dropFirst(prefix.count))
                let id = suffix.split(separator: "/").first.map(String.init)
                if id?.isEmpty == false { return id }
            }
        }

        return nil
    }

    /// Download the best audio stream from a YouTube video.
    /// Tries YouTubeKit first, falls back to yt-dlp if that fails.
    func downloadAudio(from url: URL) async throws -> (audioURL: URL, title: String) {
        guard let normalizedURL = Self.normalizedYouTubeURL(url.absoluteString) else {
            throw YouTubeError.invalidURL
        }

        downloadProgress = 0

        // Try YouTubeKit first
        do {
            return try await downloadWithYouTubeKit(from: normalizedURL)
        } catch let primaryError {
            print("[YouTube] YouTubeKit failed: \(primaryError). Falling back to yt-dlp.")
            do {
                return try await downloadWithYtDlp(from: normalizedURL)
            } catch {
                throw YouTubeError.downloadFailed("YouTubeKit: \(primaryError.localizedDescription). yt-dlp: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - YouTubeKit

    private func downloadWithYouTubeKit(from url: URL) async throws -> (audioURL: URL, title: String) {
        let video = YouTube(url: url, methods: [.local, .remote])

        // Metadata sometimes fails while stream extraction still succeeds.
        let metadata = (try? await video.metadata) ?? nil
        let cleanedTitle = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (cleanedTitle?.isEmpty == false ? cleanedTitle : nil) ?? "YouTube Video"

        let streams = try await video.streams
        let m4aStreams = streams.filterAudioOnly().filter { $0.fileExtension == .m4a }
        let audioStream: YouTubeKit.Stream? = {
            let sorted = m4aStreams.sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            if sorted.count >= 2 {
                return sorted[sorted.count / 2]
            }
            return sorted.first
        }() ?? streams.filterAudioOnly().lowestAudioBitrateStream()

        guard let stream = audioStream else {
            throw YouTubeError.noAudioStream
        }

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

    // MARK: - yt-dlp fallback

    private func downloadWithYtDlp(from url: URL) async throws -> (audioURL: URL, title: String) {
        let ytDlpPath = Self.findYtDlp()
        guard let ytDlpPath else {
            throw YouTubeError.ytDlpNotFound
        }

        // Step 1: Get the title (fast, no download)
        let (titleOutput, _) = try await runYtDlp(
            executablePath: ytDlpPath,
            arguments: [
                "--print", "%(title)s",
                "--skip-download",
                "--no-playlist",
                "--quiet",
                "--no-progress",
                "--no-warnings",
                url.absoluteString
            ]
        )
        let title = titleOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 2: Download audio
        let outputID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
        let outputTemplate = tempDir.appendingPathComponent("\(outputID).%(ext)s").path

        let _ = try await runYtDlp(
            executablePath: ytDlpPath,
            arguments: [
                "-f", "bestaudio[ext=m4a]/bestaudio",
                "--no-playlist",
                "--quiet",
                "--no-progress",
                "--no-warnings",
                "-o", outputTemplate,
                url.absoluteString
            ]
        )

        // Step 3: Find the output file (extension may vary)
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        guard let outputFile = files
            .filter({ $0.hasPrefix(outputID) && !$0.hasSuffix(".part") && !$0.hasSuffix(".ytdl") })
            .sorted()
            .first else {
            throw YouTubeError.downloadFailed("yt-dlp produced no output file")
        }

        let audioURL = tempDir.appendingPathComponent(outputFile)
        downloadProgress = 1.0

        return (audioURL: audioURL, title: title.isEmpty ? "YouTube Video" : title)
    }

    private static func findYtDlp() -> String? {
        // Check bundled binary first
        if let bundledPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("yt-dlp").path,
           FileManager.default.isExecutableFile(atPath: bundledPath) {
            return bundledPath
        }

        var paths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: pathEnv.split(separator: ":").map { "\($0)/yt-dlp" })
        }

        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runYtDlp(executablePath: String, arguments: [String]) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    var stdoutData = Data()
                    var stderrData = Data()
                    let group = DispatchGroup()

                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let details = stderr.isEmpty ? stdout : stderr
                        continuation.resume(throwing: YouTubeError.downloadFailed("yt-dlp exited with code \(process.terminationStatus): \(details)"))
                    } else {
                        continuation.resume(returning: (stdout, stderr))
                    }
                } catch {
                    continuation.resume(throwing: YouTubeError.downloadFailed("Failed to run yt-dlp: \(error.localizedDescription)"))
                }
            }
        }
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
        let observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
    }
}

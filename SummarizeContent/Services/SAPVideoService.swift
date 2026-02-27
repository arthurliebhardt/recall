import Foundation

@Observable
@MainActor
final class SAPVideoService {
    private struct YtDlpRunner {
        let executablePath: String
        let prefixArguments: [String]
        let displayName: String
    }

    enum SAPVideoError: LocalizedError {
        case invalidURL
        case downloadFailed(String)
        case ytDlpNotFound

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid SAP Video URL. Please paste a valid video.sap.com link."
            case .downloadFailed(let reason):
                return "Failed to download audio: \(reason)"
            case .ytDlpNotFound:
                return "yt-dlp not found. Install it with: brew install yt-dlp, or: python3 -m pip install yt-dlp"
            }
        }
    }

    private(set) var downloadProgress: Double = 0

    private static let sapVideoHosts: Set<String> = [
        "video.sap.com",
        "www.video.sap.com"
    ]

    /// Parse and normalize pasted SAP Video URLs. Accepts links with or without scheme.
    static func normalizedSAPVideoURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let url = components.url else {
            return nil
        }

        guard isSAPVideoURL(url) else { return nil }
        return url
    }

    /// Validate that a URL is an SAP Video URL
    static func isSAPVideoURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              sapVideoHosts.contains(host) else { return false }

        // SAP Video URLs typically have /media/ in the path
        return components.path.contains("/media/")
    }

    /// Download the best audio stream from an SAP Video using yt-dlp.
    /// Tries multiple runners:
    /// 1) yt-dlp binary
    /// 2) python3 -m yt_dlp
    /// and with/without browser cookies.
    func downloadAudio(from url: URL) async throws -> (audioURL: URL, title: String) {
        guard let normalizedURL = Self.normalizedSAPVideoURL(url.absoluteString) else {
            throw SAPVideoError.invalidURL
        }

        downloadProgress = 0
        return try await downloadWithYtDlp(from: normalizedURL)
    }

    // MARK: - yt-dlp

    private func downloadWithYtDlp(from url: URL) async throws -> (audioURL: URL, title: String) {
        let runners = Self.findYtDlpRunners()
        guard !runners.isEmpty else {
            throw SAPVideoError.ytDlpNotFound
        }

        var failures: [String] = []
        for runner in runners {
            for useBrowserCookies in [true, false] {
                do {
                    return try await downloadWithRunner(
                        runner,
                        url: url,
                        useBrowserCookies: useBrowserCookies
                    )
                } catch {
                    let cookieMode = useBrowserCookies ? "with browser cookies" : "without browser cookies"
                    failures.append("\(runner.displayName) \(cookieMode): \(error.localizedDescription)")

                    // If this runner fails on sandbox semaphore init, retrying it without cookies
                    // will not help. Skip to the next runner immediately.
                    if Self.isSemaphoreInitError(error.localizedDescription) {
                        break
                    }
                }
            }
        }

        let condensed = failures.suffix(4).joined(separator: " | ")
        throw SAPVideoError.downloadFailed("All yt-dlp strategies failed. \(condensed)")
    }

    private func downloadWithRunner(
        _ runner: YtDlpRunner,
        url: URL,
        useBrowserCookies: Bool
    ) async throws -> (audioURL: URL, title: String) {
        let cookieArgs = useBrowserCookies ? ["--cookies-from-browser", "chrome"] : []

        // Step 1: Get title quickly without downloading media.
        let (titleOutput, _) = try await runYtDlp(
            runner: runner,
            arguments: cookieArgs + [
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

        // Step 2: Download audio.
        let outputID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory
        let outputTemplate = tempDir.appendingPathComponent("\(outputID).%(ext)s").path

        _ = try await runYtDlp(
            runner: runner,
            arguments: cookieArgs + [
                "-f", "bestaudio[ext=m4a]/bestaudio/worst",
                "--no-playlist",
                "--quiet",
                "--no-progress",
                "--no-warnings",
                "-o", outputTemplate,
                url.absoluteString
            ]
        )

        // Step 3: Find the produced file.
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        guard let outputFile = files
            .filter({ $0.hasPrefix(outputID) && !$0.hasSuffix(".part") && !$0.hasSuffix(".ytdl") })
            .sorted()
            .first else {
            throw SAPVideoError.downloadFailed("yt-dlp produced no output file")
        }

        let audioURL = tempDir.appendingPathComponent(outputFile)
        downloadProgress = 1.0
        return (audioURL: audioURL, title: title.isEmpty ? "SAP Video" : title)
    }

    private static func findYtDlpRunners() -> [YtDlpRunner] {
        var ytDlpCandidates: [String] = []
        var pythonCandidates: [String] = []

        if let bundledPath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("yt-dlp").path {
            ytDlpCandidates.append(bundledPath)
        }

        ytDlpCandidates.append(contentsOf: [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ])
        pythonCandidates.append(contentsOf: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ])

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let entries = pathEnv.split(separator: ":").map(String.init)
            ytDlpCandidates.append(contentsOf: entries.map { "\($0)/yt-dlp" })
            pythonCandidates.append(contentsOf: entries.map { "\($0)/python3" })
        }

        var runners: [YtDlpRunner] = []
        var seen = Set<String>()

        for path in ytDlpCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let key = "bin:\(path)"
            guard seen.insert(key).inserted else { continue }
            runners.append(
                YtDlpRunner(
                    executablePath: path,
                    prefixArguments: [],
                    displayName: "yt-dlp (\(path))"
                )
            )
        }

        for path in pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let key = "py:\(path)"
            guard seen.insert(key).inserted else { continue }
            runners.append(
                YtDlpRunner(
                    executablePath: path,
                    prefixArguments: ["-m", "yt_dlp"],
                    displayName: "python3 -m yt_dlp (\(path))"
                )
            )
        }

        return runners
    }

    private static func isSemaphoreInitError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("failed to initialize sync semaphore")
            || message.localizedCaseInsensitiveContains("semctl: operation not permitted")
            || message.localizedCaseInsensitiveContains("sandbox semaphore restrictions")
    }

    private func runYtDlp(
        runner: YtDlpRunner,
        arguments: [String]
    ) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: runner.executablePath)
                process.arguments = runner.prefixArguments + arguments
                process.environment = ProcessInfo.processInfo.environment

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
                        if Self.isSemaphoreInitError(details) {
                            continuation.resume(
                                throwing: SAPVideoError.downloadFailed(
                                    "Runner failed due to sandbox semaphore restrictions (\(runner.displayName))."
                                )
                            )
                        } else {
                            continuation.resume(
                                throwing: SAPVideoError.downloadFailed(
                                    "\(runner.displayName) exited with code \(process.terminationStatus): \(details)"
                                )
                            )
                        }
                    } else {
                        continuation.resume(returning: (stdout, stderr))
                    }
                } catch {
                    continuation.resume(
                        throwing: SAPVideoError.downloadFailed(
                            "Failed to run \(runner.displayName): \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }
}

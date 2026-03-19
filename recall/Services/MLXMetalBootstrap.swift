import Foundation
import os

private let mlxMetalLogger = Logger(subsystem: "com.summarizecontent.app", category: "MLXMetalBootstrap")

enum MLXMetalBootstrap {
    struct ProgressStatus: Sendable {
        let fractionCompleted: Double?
        let message: String
    }

    private static let metalFlags = [
        "-x", "metal",
        "-Wall",
        "-Wextra",
        "-fno-fast-math",
        "-Wno-c++17-extensions",
        "-Wno-c++20-extensions",
    ]

    enum BootstrapError: LocalizedError {
        case packageRootNotFound
        case kernelDirectoryNotFound
        case noMetalSourcesFound
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .packageRootNotFound:
                return "Could not locate the Swift package root for MLX metallib generation."
            case .kernelDirectoryNotFound:
                return "Could not locate MLX Metal kernel sources in the SwiftPM checkout."
            case .noMetalSourcesFound:
                return "No MLX Metal shader sources were found to build the metallib."
            case .toolFailed(let message):
                return message
            }
        }
    }

    static func ensureSwiftPMMetallibIfNeeded(progress: (@Sendable (ProgressStatus) -> Void)? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ensureSwiftPMMetallibIfNeededSync(progress: progress)
        }.value
    }

    private static func ensureSwiftPMMetallibIfNeededSync(progress: (@Sendable (ProgressStatus) -> Void)? = nil) throws {
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            return
        }

        let executableDirectory = executableURL.deletingLastPathComponent()

        guard let packageRoot = findPackageRoot(startingAt: executableDirectory) else {
            throw BootstrapError.packageRootNotFound
        }

        let mlxRoot = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("checkouts")
            .appendingPathComponent("mlx-swift")
            .appendingPathComponent("Source")
            .appendingPathComponent("Cmlx")
            .appendingPathComponent("mlx")
        let kernelsDirectory = mlxRoot
            .appendingPathComponent("mlx")
            .appendingPathComponent("backend")
            .appendingPathComponent("metal")
            .appendingPathComponent("kernels")

        guard FileManager.default.fileExists(atPath: kernelsDirectory.path) else {
            throw BootstrapError.kernelDirectoryNotFound
        }

        let metalSources = try collectMetalSources(in: kernelsDirectory)
        guard !metalSources.isEmpty else {
            throw BootstrapError.noMetalSourcesFound
        }

        let cachedMetallibURL = try cachedMetallibURL(for: metalSources)
        let runtimeMetallibURL = executableDirectory.appendingPathComponent("mlx.metallib")
        if shouldReuseCachedMetallib(at: cachedMetallibURL) {
            progress?(ProgressStatus(fractionCompleted: 1.0, message: "Using cached Metal shaders..."))
            try installMetallib(from: cachedMetallibURL, to: runtimeMetallibURL)
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        mlxMetalLogger.notice("Building MLX metallib for SwiftPM run at \(runtimeMetallibURL.path)")
        progress?(ProgressStatus(fractionCompleted: 0, message: "Compiling Metal shaders..."))

        var airFiles: [URL] = []
        airFiles.reserveCapacity(metalSources.count)

        for (index, source) in metalSources.enumerated() {
            let relativePath = source.path.replacingOccurrences(of: kernelsDirectory.path + "/", with: "")
            let outputRelativePath = (relativePath as NSString).deletingPathExtension + ".air"
            let airURL = temporaryDirectory.appendingPathComponent(outputRelativePath)
            try FileManager.default.createDirectory(at: airURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress?(ProgressStatus(
                fractionCompleted: Double(index) / Double(max(metalSources.count + 1, 1)),
                message: "Compiling Metal shaders..."
            ))

            try runTool(
                "/usr/bin/xcrun",
                arguments: ["-sdk", "macosx", "metal"] + metalFlags + [
                    "-c", source.path,
                    "-I\(mlxRoot.path)",
                    "-o", airURL.path,
                ]
            )

            airFiles.append(airURL)
        }

        progress?(ProgressStatus(fractionCompleted: Double(metalSources.count) / Double(max(metalSources.count + 1, 1)), message: "Linking Metal shaders..."))

        let temporaryMetallibURL = temporaryDirectory.appendingPathComponent("mlx.metallib")
        try runTool(
            "/usr/bin/xcrun",
            arguments: ["-sdk", "macosx", "metallib"] + airFiles.map(\.path) + [
                "-o", temporaryMetallibURL.path,
            ]
        )

        try? FileManager.default.removeItem(at: cachedMetallibURL)
        try FileManager.default.copyItem(at: temporaryMetallibURL, to: cachedMetallibURL)
        try installMetallib(from: cachedMetallibURL, to: runtimeMetallibURL)
        progress?(ProgressStatus(fractionCompleted: 1.0, message: "Metal runtime ready"))
    }

    private static func cachedMetallibURL(for metalSources: [URL]) throws -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.summarizecontent.app", isDirectory: true)
            .appendingPathComponent("mlx-swiftpm", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let latestSourceDate = metalSources.compactMap(modificationDate(for:)).max() ?? .distantPast
        let sdkVersion = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let timestamp = Int(latestSourceDate.timeIntervalSince1970)
        return cacheRoot.appendingPathComponent("mlx-\(sdkVersion)-\(timestamp).metallib")
    }

    private static func shouldReuseCachedMetallib(at cachedMetallibURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: cachedMetallibURL.path)
    }

    private static func installMetallib(from sourceURL: URL, to destinationURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func modificationDate(for url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private static func findPackageRoot(startingAt directory: URL) -> URL? {
        var currentDirectory = directory.standardizedFileURL

        while true {
            let packageURL = currentDirectory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageURL.path) {
                return currentDirectory
            }

            let parent = currentDirectory.deletingLastPathComponent()
            if parent == currentDirectory {
                return nil
            }
            currentDirectory = parent
        }
    }

    private static func collectMetalSources(in directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var urls: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "metal" else { continue }
            urls.append(fileURL)
        }

        return urls.sorted { $0.path < $1.path }
    }

    private static func runTool(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = [stderrText, stdoutText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw BootstrapError.toolFailed(
                "MLX Metal bootstrap failed running `\(launchPath) \(arguments.joined(separator: " "))`.\n\(details)"
            )
        }
    }
}

@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class RecordingService: NSObject {
    enum RecordingMode: String, CaseIterable, Identifiable {
        case audio
        case screen
        case window

        var id: Self { self }

        var title: String {
            switch self {
            case .audio:
                return "Audio"
            case .screen:
                return "Screen"
            case .window:
                return "Window"
            }
        }

        var outputExtension: String {
            switch self {
            case .audio:
                return "m4a"
            case .screen, .window:
                return "mov"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case requestingPermissions(RecordingMode)
        case recording(RecordingMode, Date)
        case finishing(RecordingMode)
    }

    struct CompletedRecording: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let mode: RecordingMode
        let createdAt: Date
    }

    struct WindowCaptureTarget: Identifiable, Equatable {
        let windowID: CGWindowID
        let title: String
        let appName: String
        fileprivate let window: SCWindow

        var id: CGWindowID { windowID }

        var subtitle: String {
            if title == appName || title.isEmpty {
                return appName
            }
            return "\(appName) • \(title)"
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.windowID == rhs.windowID
        }
    }

    enum RecordingError: LocalizedError {
        case microphoneAccessDenied
        case microphoneUnavailable
        case screenCapturePermissionDenied
        case screenCaptureRequiresNewerSystem
        case noScreenAvailable
        case noWindowAvailable
        case unableToCreateRecorder
        case unableToStartRecording(RecordingMode)
        case unableToFinalizeRecording(RecordingMode)

        var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                return "Microphone access is required to record audio."
            case .microphoneUnavailable:
                return "No microphone is available on this Mac."
            case .screenCapturePermissionDenied:
                return "Screen Recording permission is required for screen or window capture."
            case .screenCaptureRequiresNewerSystem:
                return "Screen and window recording require macOS 15 or newer in this build."
            case .noScreenAvailable:
                return "No active screen is available to record."
            case .noWindowAvailable:
                return "No eligible window is available to record."
            case .unableToCreateRecorder:
                return "The recorder could not be created."
            case .unableToStartRecording(let mode):
                return "The \(mode.title.lowercased()) recording could not be started."
            case .unableToFinalizeRecording(let mode):
                return "The \(mode.title.lowercased()) recording could not be finalized."
            }
        }
    }

    private(set) var status: Status = .idle
    var latestError: String?
    var completedRecording: CompletedRecording?

    private var audioRecorder: AVAudioRecorder?
    private var screenStream: SCStream?
    private var activeOutputURL: URL?
    private var activeMode: RecordingMode?

    var isBusy: Bool {
        status != .idle
    }

    var isRecording: Bool {
        if case .recording = status {
            return true
        }
        return false
    }

    static var recordingsDirectory: URL {
        let baseDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.applicationSupportDirectory
        let directory = baseDirectory.appending(path: "Recall Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func startAudioRecording() async {
        await beginRecording(mode: .audio) {
            try await startAudioCapture()
        }
    }

    func startCurrentScreenRecording() async {
        await beginRecording(mode: .screen) {
            try await startCurrentDisplayCapture()
        }
    }

    func startWindowRecording(_ target: WindowCaptureTarget) async {
        await beginRecording(mode: .window) {
            try await startWindowCapture(target.window)
        }
    }

    func availableWindowTargets() async throws -> [WindowCaptureTarget] {
        guard await ensureScreenCaptureAccess() else {
            throw RecordingError.screenCapturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        var targets: [WindowCaptureTarget] = []

        for window in content.windows {
            let owningApplication = window.owningApplication
            let bundleID = owningApplication?.bundleIdentifier
            if bundleID == ownBundleID {
                continue
            }

            let rawAppName = owningApplication?.applicationName ?? ""
            let appName = rawAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTitle = window.title ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if appName.isEmpty && title.isEmpty {
                continue
            }

            let displayTitle = title.isEmpty ? (appName.isEmpty ? "Untitled Window" : appName) : title
            let displayAppName = appName.isEmpty ? "Unknown App" : appName
            let target = WindowCaptureTarget(
                windowID: window.windowID,
                title: displayTitle,
                appName: displayAppName,
                window: window
            )
            targets.append(target)
        }

        targets.sort {
            if $0.appName == $1.appName {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }

        return targets
    }

    func stopRecording() {
        guard case .recording(let mode, _) = status else { return }

        status = .finishing(mode)

        switch mode {
        case .audio:
            guard let audioRecorder else {
                failRecording(
                    message: RecordingError.unableToFinalizeRecording(.audio).localizedDescription,
                    cleanupURL: activeOutputURL
                )
                return
            }
            audioRecorder.stop()
        case .screen, .window:
            Task {
                await stopScreenCapture(mode: mode)
            }
        }
    }

    func clearError() {
        latestError = nil
    }

    func clearCompletedRecording() {
        completedRecording = nil
    }

    private func beginRecording(mode: RecordingMode, operation: () async throws -> Void) async {
        guard !isBusy else { return }

        latestError = nil
        completedRecording = nil
        status = .requestingPermissions(mode)

        do {
            try await operation()
        } catch {
            failRecording(message: error.localizedDescription, cleanupURL: activeOutputURL)
        }
    }

    private func startAudioCapture() async throws {
        let microphoneGranted = await requestMicrophoneAccess()
        guard microphoneGranted else {
            throw RecordingError.microphoneAccessDenied
        }

        let outputURL = Self.makeOutputURL(for: .audio)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord() else {
            throw RecordingError.unableToCreateRecorder
        }
        guard recorder.record() else {
            throw RecordingError.unableToStartRecording(.audio)
        }

        audioRecorder = recorder
        activeMode = .audio
        activeOutputURL = outputURL
        status = .recording(.audio, Date())
    }

    private func startCurrentDisplayCapture() async throws {
        guard await ensureScreenCaptureAccess() else {
            throw RecordingError.screenCapturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = currentDisplay(in: content) ?? content.displays.first else {
            throw RecordingError.noScreenAvailable
        }

        try await startScreenCapture(
            filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
            width: display.width,
            height: display.height,
            mode: .screen
        )
    }

    private func startWindowCapture(_ window: SCWindow) async throws {
        guard await ensureScreenCaptureAccess() else {
            throw RecordingError.screenCapturePermissionDenied
        }

        let width = max(Int(window.frame.width), 1)
        let height = max(Int(window.frame.height), 1)
        try await startScreenCapture(
            filter: SCContentFilter(desktopIndependentWindow: window),
            width: width,
            height: height,
            mode: .window
        )
    }

    private func startScreenCapture(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        mode: RecordingMode
    ) async throws {
        guard #available(macOS 15.0, *) else {
            throw RecordingError.screenCaptureRequiresNewerSystem
        }

        let outputURL = Self.makeOutputURL(for: mode)
        let configuration = SCStreamConfiguration()
        configuration.width = max(width, 1)
        configuration.height = max(height, 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = true

        if await requestMicrophoneAccess() {
            configuration.captureMicrophone = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)

        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()

        screenStream = stream
        activeMode = mode
        activeOutputURL = outputURL
        status = .recording(mode, Date())
    }

    private func stopScreenCapture(mode: RecordingMode) async {
        guard let outputURL = activeOutputURL else {
            failRecording(
                message: RecordingError.unableToFinalizeRecording(mode).localizedDescription,
                cleanupURL: nil
            )
            return
        }

        do {
            if let screenStream {
                try await screenStream.stopCapture()
            }
            completeRecording(at: outputURL, mode: mode)
        } catch {
            failRecording(message: error.localizedDescription, cleanupURL: outputURL)
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func ensureScreenCaptureAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = CGRequestScreenCaptureAccess()
                continuation.resume(returning: granted)
            }
        }
    }

    private func currentDisplay(in content: SCShareableContent) -> SCDisplay? {
        guard let screenNumber = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return content.displays.first { $0.displayID == displayID }
    }

    private func completeRecording(at url: URL, mode: RecordingMode) {
        resetActiveRecorderState()
        status = .idle
        completedRecording = CompletedRecording(url: url, mode: mode, createdAt: Date())
    }

    private func failRecording(message: String?, cleanupURL: URL?) {
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
        resetActiveRecorderState()
        status = .idle
        latestError = message ?? "Recording failed."
    }

    private func resetActiveRecorderState() {
        audioRecorder = nil
        screenStream = nil
        activeOutputURL = nil
        activeMode = nil
    }

    private static func makeOutputURL(for mode: RecordingMode) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "Meeting-\(mode.title)-\(formatter.string(from: Date())).\(mode.outputExtension)"
        return recordingsDirectory.appending(path: fileName)
    }
}

extension RecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if flag {
                completeRecording(at: recorder.url, mode: .audio)
            } else {
                failRecording(
                    message: RecordingError.unableToFinalizeRecording(.audio).localizedDescription,
                    cleanupURL: recorder.url
                )
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.failRecording(message: error?.localizedDescription, cleanupURL: recorder.url)
        }
    }
}

@available(macOS 15.0, *)
extension RecordingService: SCRecordingOutputDelegate {}

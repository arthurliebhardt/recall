import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var fileName: String
    var fileURL: String
    var createdAt: Date
    var duration: TimeInterval
    var segments: [TranscriptionSegment]
    var fullText: String
    var chatMessages: [ChatMessage]
    /// Path to the audio copy stored inside the app's sandbox container
    var localAudioPath: String?
    /// Custom speaker name overrides: maps original label (e.g. "Speaker 1") to user-chosen name
    var speakerNames: [String: String]

    init(
        fileName: String,
        fileURL: URL,
        duration: TimeInterval = 0,
        segments: [TranscriptionSegment] = [],
        fullText: String = "",
        localAudioPath: String? = nil
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.fileURL = fileURL.absoluteString
        self.createdAt = Date()
        self.duration = duration
        self.segments = segments
        self.fullText = fullText
        self.chatMessages = []
        self.localAudioPath = localAudioPath
        self.speakerNames = [:]
    }

    /// URL to the local audio copy inside the sandbox
    var localAudioURL: URL? {
        guard let path = localAudioPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var displayName: String {
        let name = fileName
        if let dotIndex = name.lastIndex(of: ".") {
            return String(name[name.startIndex..<dotIndex])
        }
        return name
    }

    /// Returns the display name for a speaker, using custom name if set
    func displayNameForSpeaker(_ originalLabel: String) -> String {
        speakerNames[originalLabel] ?? originalLabel
    }

    /// Rename a speaker across all segments and words
    func renameSpeaker(from originalLabel: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            speakerNames.removeValue(forKey: originalLabel)
        } else {
            speakerNames[originalLabel] = trimmed
        }
    }

    /// Directory where audio copies are stored
    static var audioStorageDirectory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "AudioFiles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct TranscriptionSegment: Codable, Identifiable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var words: [TranscriptionWord]
    var speakerLabel: String?

    init(startTime: TimeInterval, endTime: TimeInterval, text: String, words: [TranscriptionWord] = [], speakerLabel: String? = nil) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
        self.speakerLabel = speakerLabel
    }

    var formattedTimeRange: String {
        "\(Self.formatTime(startTime)) → \(Self.formatTime(endTime))"
    }

    static func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct TranscriptionWord: Codable, Identifiable {
    var id: UUID
    var word: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speakerLabel: String?

    init(word: String, startTime: TimeInterval, endTime: TimeInterval, speakerLabel: String? = nil) {
        self.id = UUID()
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
    }
}

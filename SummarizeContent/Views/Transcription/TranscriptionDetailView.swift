import SwiftUI

struct TranscriptionDetailView: View {
    let record: TranscriptionRecord

    @State private var audioPlayer = AudioPlayerService()
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var playbackTime: TimeInterval {
        isScrubbing ? scrubTime : audioPlayer.currentTime
    }

    private var isPlaybackActive: Bool {
        audioPlayer.isPlaying || isScrubbing || audioPlayer.currentTime > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .font(.headline)

                    HStack(spacing: 12) {
                        Label(record.fileName, systemImage: fileIcon)
                        Label(formatDuration(record.duration), systemImage: "clock")
                        Label(record.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    copyFullText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy full transcription")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Playback controls
            if !record.segments.isEmpty {
                PlaybackBar(
                    record: record,
                    audioPlayer: audioPlayer,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime
                )

                Divider()
            }

            // Segments
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if record.segments.isEmpty {
                            Text(record.fullText)
                                .textSelection(.enabled)
                                .padding()
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(record.segments) { segment in
                                    let isActive = isPlaybackActive
                                        && playbackTime >= segment.startTime
                                        && playbackTime < segment.endTime
                                    SegmentRow(
                                        segment: segment,
                                        isActive: isActive,
                                        playbackTime: isPlaybackActive ? playbackTime : nil,
                                        onWordTap: { word in
                                            audioPlayer.ensureLoaded(record)
                                            audioPlayer.seek(to: word.startTime)
                                            if !audioPlayer.isPlaying {
                                                audioPlayer.play()
                                            }
                                        },
                                        onTimestampTap: {
                                            audioPlayer.ensureLoaded(record)
                                            audioPlayer.seek(to: segment.startTime)
                                            if !audioPlayer.isPlaying {
                                                audioPlayer.play()
                                            }
                                        }
                                    )
                                    .id(segment.id)
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    if segment.id != record.segments.last?.id {
                                        Divider().padding(.leading)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: activeSegmentId) { _, newId in
                    if let id = newId, audioPlayer.isPlaying {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            audioPlayer.stop()
        }
    }

    private var activeSegmentId: UUID? {
        guard isPlaybackActive else { return nil }
        return record.segments.first {
            playbackTime >= $0.startTime && playbackTime < $0.endTime
        }?.id
    }

    private var fileIcon: String {
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        if AudioExtractionService.supportedVideoExtensions.contains(ext) {
            return "film"
        }
        return "waveform"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func copyFullText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.fullText, forType: .string)
    }
}

// MARK: - Playback Bar

private struct PlaybackBar: View {
    let record: TranscriptionRecord
    let audioPlayer: AudioPlayerService
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.playRecord(record)
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Text(formatTime(displayTime))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : audioPlayer.currentTime },
                    set: { newValue in
                        scrubTime = newValue
                        if !isScrubbing { isScrubbing = true }
                    }
                ),
                in: 0...max(audioPlayer.duration > 0 ? audioPlayer.duration : Double(record.duration), 0.01)
            ) { editing in
                if !editing {
                    audioPlayer.ensureLoaded(record)
                    audioPlayer.seek(to: scrubTime)
                    isScrubbing = false
                }
            }

            Text(formatTime(audioPlayer.duration > 0 ? audioPlayer.duration : record.duration))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            if let error = audioPlayer.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var displayTime: TimeInterval {
        isScrubbing ? scrubTime : audioPlayer.currentTime
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, Int(time))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Speaker Colors

private let speakerColorPalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal
]

private func colorForSpeaker(_ label: String?) -> Color? {
    guard let label else { return nil }
    // Extract the number from "Speaker N" to get a stable index
    if let numStr = label.split(separator: " ").last, let num = Int(numStr) {
        return speakerColorPalette[(num - 1) % speakerColorPalette.count]
    }
    // Fallback: hash-based
    let index = abs(label.hashValue) % speakerColorPalette.count
    return speakerColorPalette[index]
}

// MARK: - Segment Row

private struct SegmentRow: View {
    let segment: TranscriptionSegment
    let isActive: Bool
    let playbackTime: TimeInterval?
    let onWordTap: (TranscriptionWord) -> Void
    let onTimestampTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Speaker pill
            if let label = segment.speakerLabel, let color = colorForSpeaker(label) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12), in: Capsule())
                    .frame(width: 80, alignment: .leading)
            }

            // Timestamp — click to jump to segment
            Text(segment.formattedTimeRange)
                .font(.caption.monospaced())
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTimestampTap() }

            // Words — each individually tappable and highlightable
            if !segment.words.isEmpty {
                WordFlowView(
                    words: segment.words,
                    playbackTime: playbackTime,
                    isSegmentActive: isActive,
                    onWordTap: onWordTap
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(segment.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onTimestampTap() }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }
}

// MARK: - Word Flow View

private struct WordFlowView: View {
    let words: [TranscriptionWord]
    let playbackTime: TimeInterval?
    let isSegmentActive: Bool
    let onWordTap: (TranscriptionWord) -> Void

    var body: some View {
        WrappingHStack(words: words) { word in
            WordToken(
                word: word,
                isCurrent: isWordActive(word),
                onTap: { onWordTap(word) }
            )
        }
    }

    private func isWordActive(_ word: TranscriptionWord) -> Bool {
        guard let time = playbackTime, isSegmentActive else { return false }
        return time >= word.startTime && time < word.endTime
    }
}

// MARK: - Wrapping HStack (Flow Layout)

private struct WrappingHStack<Content: View>: View {
    let words: [TranscriptionWord]
    let content: (TranscriptionWord) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geometry in
            self.generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width: CGFloat = 0
        var height: CGFloat = 0

        return ZStack(alignment: .topLeading) {
            ForEach(words) { word in
                content(word)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geometry.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if word.id == words.last?.id {
                            width = 0
                        } else {
                            width -= d.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if word.id == words.last?.id {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: HeightPreferenceKey.self, value: geometry.size.height)
        }
        .onPreferenceChange(HeightPreferenceKey.self) { binding.wrappedValue = $0 }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Word Token

private struct WordToken: View {
    let word: TranscriptionWord
    let isCurrent: Bool
    let onTap: () -> Void

    private var speakerColor: Color? {
        colorForSpeaker(word.speakerLabel)
    }

    var body: some View {
        Text(word.word)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isCurrent ? Color.accentColor.opacity(0.35) : (speakerColor?.opacity(0.06) ?? Color.clear))
            )
            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
            .fontWeight(isCurrent ? .semibold : .regular)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .cursor(.pointingHand)
    }
}

// MARK: - Cursor modifier

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

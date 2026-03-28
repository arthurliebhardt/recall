import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(RecordingService.self) private var recordingService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse)
    private var records: [TranscriptionRecord]

    @Binding var showFileImporter: Bool
    @State private var showYouTubePopover = false
    @State private var showWindowPicker = false
    @State private var youTubeURLText = ""
    @State private var renamingRecord: TranscriptionRecord?
    @State private var renameText = ""

    var body: some View {
        List(selection: selectionBinding) {
            if recordingService.status != .idle {
                Section("Recording") {
                    RecordingStatusRow(status: recordingService.status)
                }
            }

            if !transcriptionVM.importJobs.isEmpty {
                Section("Importing") {
                    ForEach(transcriptionVM.importJobs) { job in
                        ImportJobRow(job: job)
                    }
                }
            }

            if !transcriptionVM.pendingRecordings.isEmpty {
                Section("Pending") {
                    ForEach(transcriptionVM.pendingRecordings) { pending in
                        PendingRecordingRow(
                            pending: pending,
                            showsAppleLocalePicker: transcriptionService.selectedBackend == .appleSpeech,
                            availableAppleLocales: transcriptionService.availableAppleLocales,
                            installedAppleLocaleIdentifiers: transcriptionService.installedAppleLocaleIdentifiers,
                            onAppleLocaleChanged: { localePreference in
                                transcriptionVM.setPendingRecordingAppleLocale(localePreference, for: pending.id)
                            },
                            onTranscribe: {
                                transcriptionVM.transcribePendingRecording(pending.id, modelContext: modelContext)
                            }
                        )
                    }
                }
            }

            ForEach(records) { record in
                SidebarRow(record: record)
                    .tag(record.id)
                    .contextMenu {
                        Button("Rename") {
                            renameText = record.displayName
                            renamingRecord = record
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            transcriptionVM.deleteRecord(record, modelContext: modelContext)
                        }
                    }
            }
        }
        .navigationTitle("Transcriptions")
        .onChange(of: recordingService.completedRecording?.id) {
            guard let recording = recordingService.completedRecording else { return }
            transcriptionVM.enqueueCompletedRecording(recording)
            recordingService.clearCompletedRecording()
        }
        .onChange(of: records.count) {
            if let selected = transcriptionVM.selectedRecord,
               !records.contains(where: { $0.id == selected.id }),
               let match = records.first {
                transcriptionVM.selectedRecord = match
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                    if recordingService.isRecording {
                        Button {
                            recordingService.stopRecording()
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .help("Stop the current recording and save it to the pending queue.")
                    } else {
                        Menu {
                            Button {
                                Task { await recordingService.startAudioRecording() }
                            } label: {
                                Label("Record Audio", systemImage: "mic.fill")
                            }

                            Button {
                                Task { await recordingService.startCurrentScreenRecording() }
                            } label: {
                                Label("Record Current Screen", systemImage: "display")
                            }

                            Button {
                                showWindowPicker = true
                            } label: {
                                Label("Record Window", systemImage: "macwindow")
                            }

#if os(macOS)
                            Divider()

                            Button {
                                NSWorkspace.shared.open(RecordingService.recordingsDirectory)
                            } label: {
                                Label("Open Recordings Folder", systemImage: "folder")
                            }
#endif
                        } label: {
                            Label("Record", systemImage: "record.circle")
                        }
                        .disabled(recordingService.isBusy)
                    }
                }

                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("From File", systemImage: "doc")
                    }
                    .keyboardShortcut("i", modifiers: .command)

                    Button {
                        showYouTubePopover = true
                    } label: {
                        Label("YouTube Link", systemImage: "play.rectangle")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .popover(isPresented: $showYouTubePopover) {
                    YouTubeImportPopover(
                        urlText: $youTubeURLText,
                        isPresented: $showYouTubePopover
                    )
                }
            }
        }
        .sheet(isPresented: $showWindowPicker) {
            WindowRecordingPicker(isPresented: $showWindowPicker)
        }
        .overlay {
            if records.isEmpty && transcriptionVM.importJobs.isEmpty {
                emptyStateView
            }
        }
        .alert("Rename", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let record = renamingRecord {
                    let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty else { return }
                    // Preserve the file extension
                    let ext = (record.fileName as NSString).pathExtension
                    record.fileName = ext.isEmpty ? newName : "\(newName).\(ext)"
                    try? modelContext.save()
                }
                renamingRecord = nil
            }
            Button("Cancel", role: .cancel) {
                renamingRecord = nil
            }
        } message: {
            Text("Enter a new name for this transcription.")
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: {
                renamingRecord != nil
            },
            set: { isPresented in
                if !isPresented {
                    renamingRecord = nil
                }
            }
        )
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: {
                transcriptionVM.selectedRecord?.id
            },
            set: { newID in
                transcriptionVM.selectedRecord = records.first { $0.id == newID }
            }
        )
    }

    @ViewBuilder
    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Transcriptions",
            systemImage: "waveform",
            description: Text("Import a file or start a recording to get a transcript.")
        )
    }
}

private struct RecordingStatusRow: View {
    let status: RecordingService.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if case .recording = status {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(title)
                    .font(.headline)
            }

            HStack(spacing: 6) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .help("Saved in \(RecordingService.recordingsDirectory.path)")
    }

    private var title: String {
        switch status {
        case .idle:
            return "Ready"
        case .requestingPermissions(let mode):
            return "Preparing \(mode.title) Recording"
        case .recording(let mode, _):
            return "Recording \(mode.title)"
        case .finishing(let mode):
            return "Finishing \(mode.title) Recording"
        }
    }

    private var subtitle: String {
        switch status {
        case .idle:
            return ""
        case .requestingPermissions(.audio):
            return "Waiting for microphone permission"
        case .requestingPermissions(.screen):
            return "Waiting for screen recording permission"
        case .requestingPermissions(.window):
            return "Preparing the selected window capture"
        case .recording(.audio, _):
            return "Audio is being saved to the Documents folder"
        case .recording(.screen, _):
            return "Screen video is being saved to the Documents folder"
        case .recording(.window, _):
            return "Window video is being saved to the Documents folder"
        case .finishing(.audio):
            return "Stopping audio capture and saving the recording"
        case .finishing(.screen):
            return "Stopping screen capture and saving the recording"
        case .finishing(.window):
            return "Stopping window capture and saving the recording"
        }
    }

    private var startedAt: Date? {
        if case .recording(_, let startedAt) = status {
            return startedAt
        }
        return nil
    }
}

private struct WindowRecordingPicker: View {
    @Environment(RecordingService.self) private var recordingService
    @Binding var isPresented: Bool
    @State private var windows: [RecordingService.WindowCaptureTarget] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a Window")
                .font(.headline)

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading available windows...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Could Not Load Windows",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if windows.isEmpty {
                    ContentUnavailableView(
                        "No Windows Available",
                        systemImage: "macwindow",
                        description: Text("Open the meeting window you want to capture, then try again.")
                    )
                } else {
                    List(windows) { target in
                        Button {
                            isPresented = false
                            Task {
                                await recordingService.startWindowRecording(target)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target.title)
                                    .foregroundStyle(.primary)
                                Text(target.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 360)
        .task {
            await loadWindows()
        }
    }

    private func loadWindows() async {
        isLoading = true
        loadError = nil

        do {
            windows = try await recordingService.availableWindowTargets()
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }
}

private struct YouTubeImportPopover: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(\.modelContext) private var modelContext
    @Binding var urlText: String
    @Binding var isPresented: Bool
    @State private var importMode: TranscriptionViewModel.YouTubeImportMode = .transcriptOnly

    private var isValidURL: Bool {
        YouTubeService.normalizedYouTubeURL(urlText) != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Import from YouTube")
                .font(.headline)

            TextField("Paste YouTube URL...", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { importIfValid() }

            VStack(alignment: .leading, spacing: 8) {
                Text("Import Mode")
                    .font(.subheadline.weight(.medium))

                Picker("Import Mode", selection: $importMode) {
                    ForEach(TranscriptionViewModel.YouTubeImportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(importMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320, alignment: .leading)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    importIfValid()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidURL)
            }
        }
        .padding()
    }

    private func importIfValid() {
        guard let url = YouTubeService.normalizedYouTubeURL(urlText) else { return }
        isPresented = false
        transcriptionVM.importYouTubeURL(url, mode: importMode, modelContext: modelContext)
        urlText = ""
        importMode = .transcriptOnly
    }
}

private struct ImportJobRow: View {
    let job: TranscriptionViewModel.ImportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let progress = progressValue {
                    Text("(\(Int(progress * 100))%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = progressValue, progress > 0 {
                ProgressView(value: progress)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch job.state {
        case .fetchingYouTubeTranscript: return "Fetching transcript..."
        case .downloadingYouTube: return "Downloading..."
        case .extractingAudio: return "Extracting audio..."
        case .transcribing: return "Transcribing..."
        case .diarizing: return "Identifying speakers..."
        case .saving: return "Saving..."
        }
    }

    private var progressValue: Double? {
        switch job.state {
        case .downloadingYouTube(let p) where p > 0: return p
        case .transcribing(let p) where p > 0: return p
        default: return nil
        }
    }
}

private struct PendingRecordingRow: View {
    let pending: TranscriptionViewModel.PendingRecording
    let showsAppleLocalePicker: Bool
    let availableAppleLocales: [Locale]
    let installedAppleLocaleIdentifiers: Set<String>
    let onAppleLocaleChanged: (String) -> Void
    let onTranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.recording.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(pending.recording.createdAt, style: .date)
                Text(pending.recording.createdAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showsAppleLocalePicker {
                Picker(
                    "Language",
                    selection: Binding(
                        get: { pending.appleLocalePreference },
                        set: onAppleLocaleChanged
                    )
                ) {
                    Text("Use macOS Language").tag(TranscriptionService.systemLocalePreferenceValue)

                    ForEach(availableAppleLocales, id: \.identifier) { locale in
                        Text(appleLocaleLabel(for: locale)).tag(locale.identifier)
                    }
                }
            }

            Button("Transcribe") {
                onTranscribe()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private func appleLocaleLabel(for locale: Locale) -> String {
        let name = TranscriptionService.displayName(for: locale)
        if installedAppleLocaleIdentifiers.contains(locale.identifier) {
            return "\(name) (downloaded)"
        }
        return name
    }
}

private struct SidebarRow: View {
    let record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.displayName)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(record.createdAt, style: .date)
                Text(formatDuration(record.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

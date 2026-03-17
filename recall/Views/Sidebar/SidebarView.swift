import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse)
    private var records: [TranscriptionRecord]

    @Binding var showFileImporter: Bool
    @State private var showYouTubePopover = false
    @State private var youTubeURLText = ""
    @State private var renamingRecord: TranscriptionRecord?
    @State private var renameText = ""

    var body: some View {
        @Bindable var transcriptionVM = transcriptionVM

        List(selection: Binding(
            get: { transcriptionVM.selectedRecord?.id },
            set: { newId in
                transcriptionVM.selectedRecord = records.first { $0.id == newId }
            }
        )) {
            if !transcriptionVM.importJobs.isEmpty {
                Section("Importing") {
                    ForEach(transcriptionVM.importJobs) { job in
                        ImportJobRow(job: job)
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
        .onChange(of: records.count) {
            if let selected = transcriptionVM.selectedRecord,
               !records.contains(where: { $0.id == selected.id }),
               let match = records.first {
                transcriptionVM.selectedRecord = match
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
        .overlay {
            if records.isEmpty && transcriptionVM.importJobs.isEmpty {
                ContentUnavailableView {
                    Label("No Transcriptions", systemImage: "waveform")
                } description: {
                    Text("Click + to import an audio or video file.")
                }
            }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingRecord != nil },
            set: { if !$0 { renamingRecord = nil } }
        )) {
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
}

private struct YouTubeImportPopover: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(\.modelContext) private var modelContext
    @Binding var urlText: String
    @Binding var isPresented: Bool

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
        transcriptionVM.importYouTubeURL(url, modelContext: modelContext)
        urlText = ""
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

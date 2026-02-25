import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(ChatViewModel.self) private var chatVM
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(LLMService.self) private var llmService
    @Environment(DiarizationService.self) private var diarizationService
    @Environment(\.modelContext) private var modelContext

    @State private var showFileImporter = false

    var body: some View {
        @Bindable var transcriptionVM = transcriptionVM

        NavigationSplitView {
            SidebarView(showFileImporter: $showFileImporter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            HSplitView {
                // Transcription panel
                Group {
                    if let record = transcriptionVM.selectedRecord {
                        TranscriptionDetailView(record: record)
                    } else {
                        ContentUnavailableView(
                            "No Transcription Selected",
                            systemImage: "waveform",
                            description: Text("Import an audio or video file to get started.")
                        )
                    }
                }
                .frame(minWidth: 300, idealWidth: 500)

                // Chat panel
                Group {
                    if let record = transcriptionVM.selectedRecord {
                        ChatView(record: record)
                    } else {
                        ContentUnavailableView(
                            "Chat",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Select a transcription to start chatting.")
                        )
                    }
                }
                .frame(minWidth: 300, idealWidth: 450)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                transcriptionVM.importFile(url, modelContext: modelContext)
            case .failure(let error):
                print("File import error: \(error.localizedDescription)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .alert(
            "Import Error",
            isPresented: Binding(
                get: { transcriptionVM.latestError != nil },
                set: { if !$0 { transcriptionVM.clearError() } }
            )
        ) {
            Button("OK") { transcriptionVM.clearError() }
        } message: {
            if let msg = transcriptionVM.latestError {
                Text(msg)
            }
        }
        .overlay {
            if !transcriptionService.modelState.isReady || !llmService.modelState.isReady || !diarizationService.modelState.isReady {
                ModelLoadingOverlay(
                    whisperState: transcriptionService.modelState,
                    llmState: llmService.modelState,
                    diarizationState: diarizationService.modelState
                )
            }
        }
        .task {
            async let whisper: Void = {
                if !transcriptionService.modelState.isReady {
                    await transcriptionService.loadModel()
                }
            }()
            async let llm: Void = {
                if !llmService.modelState.isReady {
                    await llmService.loadModel()
                }
            }()
            async let diarization: Void = {
                if !diarizationService.modelState.isReady {
                    await diarizationService.prepareModels()
                }
            }()
            _ = await (whisper, llm, diarization)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    transcriptionVM.importFile(url, modelContext: modelContext)
                }
            }
        }
    }
}

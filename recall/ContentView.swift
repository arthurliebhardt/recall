import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TranscriptionViewModel.self) private var transcriptionVM
    @Environment(ChatViewModel.self) private var chatVM
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(RecordingService.self) private var recordingService
    @Environment(LLMService.self) private var llmService
    @Environment(DiarizationService.self) private var diarizationService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("transcriptionBackend") private var savedTranscriptionBackend = TranscriptionService.defaultBackend.rawValue
    @AppStorage("whisperModel") private var savedWhisperModel = TranscriptionService.defaultModel
    @AppStorage("appleSpeechLocalePreference") private var savedAppleSpeechLocalePreference = TranscriptionService.systemLocalePreferenceValue
    @AppStorage("llmModel") private var savedLLMModel = LLMService.defaultModelId

    @State private var showFileImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var transcriptionVM = transcriptionVM

        NavigationSplitView {
            SidebarView(showFileImporter: $showFileImporter)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                            Text("Drop to import")
                                .font(.title3.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert(
            activeAlert.title,
            isPresented: alertPresentedBinding
        ) {
            if let settingsURL = activeAlert.settingsURL {
                Button("Open Settings") {
                    openURL(settingsURL)
                    clearErrors()
                }
            }

            Button(activeAlert.dismissLabel) {
                clearErrors()
            }
        } message: {
            Text(activeAlert.message)
        }
        .overlay {
            if !hasCompletedOnboarding {
                OnboardingView {
                    withAnimation {
                        hasCompletedOnboarding = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !transcriptionService.isReadyForTranscription || !llmService.modelState.isReady || !diarizationService.modelState.isReady {
                ModelLoadingOverlay(
                    transcriptionBackend: transcriptionService.selectedBackend,
                    transcriptionState: transcriptionService.modelState,
                    llmState: llmService.modelState,
                    diarizationState: diarizationService.modelState
                )
            }
        }
        .task(id: startupConfigurationKey) {
            guard hasCompletedOnboarding else { return }

            let resolvedBackend = TranscriptionService.resolveBackend(savedTranscriptionBackend)
            if savedTranscriptionBackend != resolvedBackend.rawValue {
                savedTranscriptionBackend = resolvedBackend.rawValue
            }
            await transcriptionService.setBackend(resolvedBackend)
            await transcriptionService.setAppleLocalePreference(savedAppleSpeechLocalePreference)

            let resolvedLLMModel = LLMService.resolvePersistedModelId(savedLLMModel)
            if savedLLMModel != resolvedLLMModel {
                savedLLMModel = resolvedLLMModel
            }
            let shouldPrepareTranscription = !transcriptionService.isReadyForTranscription
            let shouldLoadLLM = !llmService.modelState.isReady
            let shouldPrepareDiarization = !diarizationService.modelState.isReady

            async let transcription: Void = {
                if shouldPrepareTranscription {
                    await transcriptionService.prepareSelectedBackend(whisperVariant: savedWhisperModel)
                }
            }()
            async let llm: Void = {
                if shouldLoadLLM {
                    await llmService.loadModel(resolvedLLMModel)
                }
            }()
            async let diarization: Void = {
                if shouldPrepareDiarization {
                    await diarizationService.prepareModels()
                }
            }()
            _ = await (transcription, llm, diarization)
        }
    }

    private var startupConfigurationKey: String {
        [
            hasCompletedOnboarding ? "1" : "0",
            savedTranscriptionBackend,
            savedWhisperModel,
            savedAppleSpeechLocalePreference,
            savedLLMModel,
        ].joined(separator: "|")
    }

    private var alertPresentedBinding: Binding<Bool> {
        Binding(
            get: { transcriptionVM.latestError != nil || recordingService.latestError != nil },
            set: { isPresented in
                if !isPresented {
                    clearErrors()
                }
            }
        )
    }

    private var activeAlert: AppAlert {
        if let recordingError = recordingService.latestError {
            if recordingError == RecordingService.RecordingError.screenCapturePermissionDenied.localizedDescription {
                return AppAlert(
                    title: "Screen Recording Access Needed",
                    message: """
                    To record your screen or a specific window:

                    1. Open System Settings.
                    2. Go to Privacy & Security > Screen Recording.
                    3. Enable access for recall.
                    4. Quit and reopen recall if macOS asks you to.
                    """,
                    dismissLabel: "Not Now",
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                )
            }

            if recordingError == RecordingService.RecordingError.microphoneAccessDenied.localizedDescription {
                return AppAlert(
                    title: "Microphone Access Needed",
                    message: """
                    To record audio:

                    1. Open System Settings.
                    2. Go to Privacy & Security > Microphone.
                    3. Enable access for recall.
                    4. Return to recall and try again.
                    """,
                    dismissLabel: "Not Now",
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                )
            }

            return AppAlert(title: "Error", message: recordingError)
        }

        return AppAlert(title: "Error", message: transcriptionVM.latestError ?? "Something went wrong.")
    }

    private func clearErrors() {
        transcriptionVM.clearError()
        recordingService.clearError()
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

private struct AppAlert {
    let title: String
    let message: String
    let dismissLabel: String
    let settingsURL: URL?

    init(title: String, message: String, dismissLabel: String = "OK", settingsURL: URL? = nil) {
        self.title = title
        self.message = message
        self.dismissLabel = dismissLabel
        self.settingsURL = settingsURL
    }
}

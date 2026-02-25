import SwiftUI

struct SettingsView: View {
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(LLMService.self) private var llmService

    @State private var selectedWhisperModel = TranscriptionService.defaultModel
    @State private var selectedLLMModel = LLMService.defaultModelId
    @State private var availableWhisperModels: [String] = []

    @AppStorage("whisperModel") private var savedWhisperModel = TranscriptionService.defaultModel
    @AppStorage("llmModel") private var savedLLMModel = LLMService.defaultModelId

    var body: some View {
        TabView {
            whisperSettings
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            llmSettings
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }
        }
        .frame(width: 500, height: 350)
        .task {
            availableWhisperModels = await transcriptionService.fetchAvailableModels()
            selectedWhisperModel = savedWhisperModel
            selectedLLMModel = savedLLMModel
        }
    }

    // MARK: - Whisper Settings

    private var whisperSettings: some View {
        Form {
            Section("Whisper Model") {
                Picker("Model", selection: $selectedWhisperModel) {
                    ForEach(whisperModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                modelStateView(for: transcriptionService.modelState)

                HStack {
                    Button("Load Model") {
                        savedWhisperModel = selectedWhisperModel
                        Task {
                            await transcriptionService.loadModel(selectedWhisperModel)
                        }
                    }
                    .disabled(transcriptionService.modelState.isReady
                              && transcriptionService.modelState.modelName == selectedWhisperModel)

                    if transcriptionService.modelState.isReady {
                        Button("Unload") {
                            transcriptionService.unloadModel()
                        }
                    }
                }
            }

            Section("Info") {
                Text("WhisperKit runs transcription locally on your Mac using CoreML.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Larger models are more accurate but use more memory and take longer to load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - LLM Settings

    private var llmSettings: some View {
        Form {
            Section("LLM Model") {
                TextField("HuggingFace Model ID", text: $selectedLLMModel)
                    .textFieldStyle(.roundedBorder)

                modelStateView(for: llmService.modelState)

                HStack {
                    Button("Load Model") {
                        savedLLMModel = selectedLLMModel
                        Task {
                            await llmService.loadModel(selectedLLMModel)
                        }
                    }
                    .disabled(llmService.modelState.isReady
                              && llmService.modelState.modelName == selectedLLMModel)

                    if llmService.modelState.isReady {
                        Button("Unload") {
                            llmService.unloadModel()
                        }
                    }
                }
            }

            Section("Suggested Models") {
                VStack(alignment: .leading, spacing: 4) {
                    modelSuggestion("mlx-community/Qwen3-4B-4bit", size: "~2.5 GB")
                    modelSuggestion("mlx-community/Llama-3.2-3B-Instruct-4bit", size: "~1.8 GB")
                    modelSuggestion("mlx-community/gemma-3-4b-it-qat-4bit", size: "~2.5 GB")
                }
            }

            Section("Info") {
                Text("Models run locally using Apple MLX. First load will download the model from HuggingFace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var whisperModelOptions: [String] {
        if availableWhisperModels.isEmpty {
            return [TranscriptionService.defaultModel, "openai_whisper-large-v3_turbo", "large-v3", "tiny.en"]
        }
        // Ensure the selected model is always in the list
        var models = availableWhisperModels
        if !models.contains(selectedWhisperModel) {
            models.insert(selectedWhisperModel, at: 0)
        }
        return models
    }

    // MARK: - Helpers

    @ViewBuilder
    private func modelStateView<S: Equatable>(for state: S) -> some View {
        if let whisperState = state as? TranscriptionService.ModelState {
            whisperModelStatus(whisperState)
        } else if let llmState = state as? LLMService.ModelState {
            llmModelStatus(llmState)
        }
    }

    @ViewBuilder
    private func whisperModelStatus(_ state: TranscriptionService.ModelState) -> some View {
        switch state {
        case .notLoaded:
            Label("Not loaded", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                    .frame(width: 150)
                Text("\(Int(progress * 100))%")
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading...")
            }
        case .loaded(let name):
            Label("Loaded: \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func llmModelStatus(_ state: LLMService.ModelState) -> some View {
        switch state {
        case .notLoaded:
            Label("Not loaded", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                    .frame(width: 150)
                Text("\(Int(progress * 100))%")
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading...")
            }
        case .loaded(let name):
            Label("Loaded: \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func modelSuggestion(_ id: String, size: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(id)
                    .font(.caption.monospaced())
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Use") {
                selectedLLMModel = id
            }
            .controlSize(.small)
        }
    }
}

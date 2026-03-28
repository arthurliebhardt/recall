import SwiftUI

struct SettingsView: View {
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(LLMService.self) private var llmService

    @State private var selectedBackend = TranscriptionService.defaultBackend
    @State private var selectedWhisperModel = TranscriptionService.defaultModel
    @State private var selectedAppleLocalePreference = TranscriptionService.systemLocalePreferenceValue
    @State private var selectedTranscriptionProfile = TranscriptionService.defaultPerformanceProfile
    @State private var selectedLLMModel = LLMService.defaultModelId
    @State private var availableWhisperModels: [String] = []

    @AppStorage("transcriptionBackend") private var savedTranscriptionBackend = TranscriptionService.defaultBackend.rawValue
    @AppStorage("whisperModel") private var savedWhisperModel = TranscriptionService.defaultModel
    @AppStorage("transcriptionPerformanceProfile") private var savedTranscriptionProfile = TranscriptionService.defaultPerformanceProfile.rawValue
    @AppStorage("llmModel") private var savedLLMModel = LLMService.defaultModelId

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        TabView {
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            llmSettings
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }

            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 500, height: 350)
        .task {
            let resolvedBackend = TranscriptionService.resolveBackend(savedTranscriptionBackend)
            if savedTranscriptionBackend != resolvedBackend.rawValue {
                savedTranscriptionBackend = resolvedBackend.rawValue
            }
            selectedBackend = resolvedBackend
            await transcriptionService.setBackend(resolvedBackend)
            await transcriptionService.refreshAppleLocaleInventory()
            availableWhisperModels = await transcriptionService.fetchAvailableModels()
            selectedWhisperModel = savedWhisperModel
            selectedAppleLocalePreference = transcriptionService.appleLocalePreference
            selectedTranscriptionProfile = TranscriptionService.resolvePerformanceProfile(savedTranscriptionProfile)
            let resolvedLLMModel = LLMService.resolvePersistedModelId(savedLLMModel)
            if savedLLMModel != resolvedLLMModel {
                savedLLMModel = resolvedLLMModel
            }
            selectedLLMModel = resolvedLLMModel
        }
    }

    // MARK: - Transcription Settings

    private var transcriptionSettings: some View {
        Form {
            Section("Backend") {
                Picker("Engine", selection: $selectedBackend) {
                    ForEach(transcriptionService.availableBackends) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .onChange(of: selectedBackend) { _, newValue in
                    savedTranscriptionBackend = newValue.rawValue
                    Task {
                        await transcriptionService.setBackend(newValue)
                        selectedAppleLocalePreference = transcriptionService.appleLocalePreference
                    }
                }

                Text(selectedBackend.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if selectedBackend == .whisperKit {
                Section("Whisper Model") {
                    Picker("Model", selection: $selectedWhisperModel) {
                        ForEach(whisperModelOptions, id: \.self) { model in
                            Text(whisperModelLabel(for: model)).tag(model)
                        }
                    }

                    modelStateView(for: transcriptionService.modelState)

                    HStack {
                        Button("Load Model") {
                            savedWhisperModel = selectedWhisperModel
                            Task {
                                await transcriptionService.prepareSelectedBackend(whisperVariant: selectedWhisperModel)
                            }
                        }
                        .disabled(transcriptionService.modelState.isReady
                                  && transcriptionService.modelState.modelName == selectedWhisperModel)

                        if transcriptionService.modelState.isReady {
                            Button("Unload") {
                                Task {
                                    await transcriptionService.unloadSelectedBackend()
                                }
                            }
                        }
                    }

                    Text("Use a multilingual Whisper model for German and other non-English transcripts. `tiny.en` is English-only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Transcription Profile") {
                    Picker("Profile", selection: $selectedTranscriptionProfile) {
                        ForEach(TranscriptionService.PerformanceProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTranscriptionProfile) { _, newValue in
                        savedTranscriptionProfile = newValue.rawValue
                    }

                    Text(selectedTranscriptionProfile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Applies to new transcriptions only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Apple Speech") {
                    Picker("Language", selection: $selectedAppleLocalePreference) {
                        Text(systemAppleLocaleLabel).tag(TranscriptionService.systemLocalePreferenceValue)

                        ForEach(transcriptionService.availableAppleLocales, id: \.identifier) { locale in
                            Text(appleLocaleLabel(for: locale)).tag(locale.identifier)
                        }
                    }
                    .onChange(of: selectedAppleLocalePreference) { _, newValue in
                        Task {
                            await transcriptionService.setAppleLocalePreference(newValue)
                            selectedAppleLocalePreference = transcriptionService.appleLocalePreference
                        }
                    }

                    modelStateView(for: transcriptionService.modelState)

                    HStack {
                        Button("Prepare") {
                            Task {
                                await transcriptionService.prepareSelectedBackend(whisperVariant: selectedWhisperModel)
                            }
                        }
                        .disabled(transcriptionService.modelState.isReady)

                        if transcriptionService.modelState.isReady {
                            Button("Release") {
                                Task {
                                    await transcriptionService.unloadSelectedBackend()
                                }
                            }
                        }
                    }

                    Text("Apple Speech uses one locale per transcriber. Choose a supported language and the system downloads assets only if they are missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(appleLocaleSecondaryInfoLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Transcription Profile") {
                    Picker("Profile", selection: $selectedTranscriptionProfile) {
                        ForEach(TranscriptionService.PerformanceProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTranscriptionProfile) { _, newValue in
                        savedTranscriptionProfile = newValue.rawValue
                    }

                    Text(selectedTranscriptionProfile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Info") {
                Text(transcriptionInfoLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transcriptionSecondaryInfoLine)
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
                        let resolvedLLMModel = LLMService.normalizeModelId(selectedLLMModel)
                        savedLLMModel = resolvedLLMModel
                        selectedLLMModel = resolvedLLMModel
                        Task {
                            await llmService.loadModel(resolvedLLMModel)
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
                    modelSuggestion(LLMService.defaultModelId, note: "Default")
                    modelSuggestion("mlx-community/Llama-3.2-3B-Instruct-4bit", note: "Smaller alternative")
                    modelSuggestion("mlx-community/Qwen3-8B-4bit", note: "Larger alternative")
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

    // MARK: - General Settings

    private var generalSettings: some View {
        Form {
            Section("Onboarding") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart Onboarding")
                        Text("Re-run the initial setup wizard to change models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restart") {
                        hasCompletedOnboarding = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var whisperModelOptions: [String] {
        if availableWhisperModels.isEmpty {
            return [TranscriptionService.defaultModel, "openai_whisper-large-v3_turbo", "large-v3"]
        }
        // Ensure the selected model is always in the list
        var models = availableWhisperModels
        if !models.contains(selectedWhisperModel) {
            models.insert(selectedWhisperModel, at: 0)
        }
        return models
    }

    private func whisperModelLabel(for model: String) -> String {
        model == "tiny.en" ? "\(model) (English only)" : model
    }

    private func appleLocaleLabel(for locale: Locale) -> String {
        let name = TranscriptionService.displayName(for: locale)
        if transcriptionService.installedAppleLocaleIdentifiers.contains(locale.identifier) {
            return "\(name) (downloaded)"
        }
        return name
    }

    private var systemAppleLocaleLabel: String {
        let base = "Use macOS Language"
        guard let resolvedIdentifier = transcriptionService.resolvedAppleLocaleIdentifier else {
            return base
        }

        let locale = Locale(identifier: resolvedIdentifier)
        return "\(base) (\(TranscriptionService.displayName(for: locale)))"
    }

    private var appleLocaleSecondaryInfoLine: String {
        let resolvedIdentifier = transcriptionService.resolvedAppleLocaleIdentifier ?? selectedAppleLocalePreference
        guard resolvedIdentifier != TranscriptionService.systemLocalePreferenceValue else {
            return "This follows your current macOS language and region. Apple Speech does not auto-detect the spoken language from audio."
        }

        let locale = Locale(identifier: resolvedIdentifier)
        let prefix = "Selected locale: \(TranscriptionService.displayName(for: locale))."
        if transcriptionService.installedAppleLocaleIdentifiers.contains(resolvedIdentifier) {
            return "\(prefix) Speech assets are already installed on this Mac. Apple Speech does not auto-detect the spoken language from audio."
        }
        return "\(prefix) Speech assets will download when you prepare this backend. Apple Speech does not auto-detect the spoken language from audio."
    }

    // MARK: - Helpers

    @ViewBuilder
    private func modelStateView<S: Equatable>(for state: S) -> some View {
        if let whisperState = state as? TranscriptionService.ModelState {
            transcriptionModelStatus(whisperState)
        } else if let llmState = state as? LLMService.ModelState {
            llmModelStatus(llmState)
        }
    }

    @ViewBuilder
    private func transcriptionModelStatus(_ state: TranscriptionService.ModelState) -> some View {
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

    private var transcriptionInfoLine: String {
        switch selectedBackend {
        case .appleSpeech:
            return "Apple Speech runs fully on-device through the SpeechAnalyzer framework."
        case .whisperKit:
            return "WhisperKit runs transcription locally on your Mac using CoreML."
        }
    }

    private var transcriptionSecondaryInfoLine: String {
        switch selectedBackend {
        case .appleSpeech:
            return "Apple Speech is only available on supported Macs running macOS 26 or later."
        case .whisperKit:
            return "Larger Whisper models are more accurate but use more memory and take longer to load."
        }
    }

    @ViewBuilder
    private func llmModelStatus(_ state: LLMService.ModelState) -> some View {
        switch state {
        case .notLoaded:
            Label("Not loaded", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .preparing(let progress, let message):
            if let progress {
                HStack {
                    ProgressView(value: progress)
                        .frame(width: 150)
                    Text(message)
                        .lineLimit(2)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
            }
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

    private func modelSuggestion(_ id: String, note: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(id)
                    .font(.caption.monospaced())
                Text("\(note) • Recommended RAM: \(LLMService.recommendedRAM(for: id))")
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

import SwiftUI

struct OnboardingView: View {
    @Environment(TranscriptionService.self) private var transcriptionService

    @AppStorage("whisperModel") private var savedWhisperModel = TranscriptionService.defaultModel
    @AppStorage("llmModel") private var savedLLMModel = LLMService.defaultModelId

    @State private var step = 0
    @State private var selectedWhisperModel = TranscriptionService.defaultModel
    @State private var llmSelection: LLMSelection = .defaultModel
    @State private var customPickerSelection = ""
    @State private var manualModelText = ""
    @State private var customIsManual = false
    @State private var availableWhisperModels: [String] = []
    @State private var cachedModels: [(id: String, size: String)] = []
    @State private var selectedCachedModel: String = ""
    private let manualEntryTag = "_manual_"

    private static let otherLLMs: [(id: String, size: String)] = [
        ("mlx-community/Qwen3-8B-4bit", "~4.9 GB"),
        ("mlx-community/Phi-4-mini-instruct-4bit", "~2.4 GB"),
        ("mlx-community/gemma-3-4b-it-qat-4bit", "~2.5 GB"),
        ("mlx-community/Mistral-7B-Instruct-v0.3-4bit", "~3.8 GB"),
        ("mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", "~4.5 GB"),
        ("mlx-community/GLM-4.7-4bit", "~5.3 GB"),
        ("mlx-community/Qwen3-14B-4bit", "~8.5 GB"),
        ("mlx-community/Qwen3-30B-A3B-4bit", "~17 GB"),
        ("mlx-community/DeepSeek-V3.1-4bit", "~38 GB"),
        ("mlx-community/Llama-3.3-70B-Instruct-4bit", "~40 GB"),
    ]

    var onComplete: () -> Void

    // MARK: - LLM Selection

    private enum LLMSelection {
        case defaultModel
        case custom

        var modelId: String? {
            switch self {
            case .defaultModel: LLMService.defaultModelId
            case .custom: nil
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                switch step {
                case 0:
                    welcomeStep
                case 1:
                    whisperStep
                case 2:
                    cachedModelStep
                case 3:
                    llmStep
                default:
                    EmptyView()
                }
            }
            .padding(32)
            .frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20, y: 10)
        }
        .onAppear(perform: configureInitialLLMSelection)
        .task {
            let models = await transcriptionService.fetchAvailableModels()
            if !models.isEmpty {
                availableWhisperModels = models
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            Text("Welcome to recall.")
                .font(.title.weight(.bold))

            Text("recall transcribes audio & video locally on your Mac using AI models. Let's set up your models.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation { step = 1 }
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 2: Transcription Model

    private var whisperStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Transcription Model")
                .font(.title2.weight(.semibold))

            Text("Whisper converts speech to text. The turbo model is recommended for fast, accurate transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Model", selection: $selectedWhisperModel) {
                ForEach(whisperModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()

            Button {
                scanCachedModels()
                if cachedModels.isEmpty {
                    withAnimation { step = 3 }
                } else {
                    selectedCachedModel = cachedModels[0].id
                    withAnimation { step = 2 }
                }
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Step 3: Cached Models

    private var cachedModelStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Previously Downloaded Models")
                .font(.title2.weight(.semibold))

            Text("We found models already on your Mac. Select one or download a new model.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(cachedModels, id: \.id) { model in
                    Button {
                        selectedCachedModel = model.id
                    } label: {
                        HStack {
                            Image(systemName: selectedCachedModel == model.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedCachedModel == model.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortModelName(model.id))
                                    .font(.callout.weight(.medium))
                                Text("\(model.id) — \(model.size)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 8) {
                Button {
                    savedWhisperModel = selectedWhisperModel
                    savedLLMModel = "mlx-community/\(selectedCachedModel)"
                    onComplete()
                } label: {
                    Text("Use Selected Model")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    withAnimation { step = 3 }
                } label: {
                    Text("Download a Different Model")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Button("Back") {
                withAnimation { step = 1 }
            }
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 4: LLM Model

    private var llmStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Select Model")
                    .font(.title3.weight(.semibold))

                Picker("Select a model", selection: llmPickerSelection) {
                    Text("Qwen 3.5 9B (Default)").tag(LLMService.defaultModelId)
                    ForEach(Self.otherLLMs, id: \.id) { model in
                        Text("\(shortModelName(model.id))  (\(model.size))").tag(model.id)
                    }
                    Divider()
                    Text("Enter manually…").tag(manualEntryTag)
                }
                .labelsHidden()

                if customIsManual {
                    TextField("mlx-community/model-name", text: $manualModelText)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
            }

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { step = cachedModels.isEmpty ? 1 : 2 }
                }
                .controlSize(.large)

                Button {
                    finishOnboarding()
                } label: {
                    Text("Finish Setup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(customIsManual && resolvedCustomModel.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private var llmPickerSelection: Binding<String> {
        Binding(
            get: {
                if llmSelection == .defaultModel {
                    return LLMService.defaultModelId
                }
                return customIsManual ? manualEntryTag : customPickerSelection
            },
            set: { newValue in
                if newValue == LLMService.defaultModelId {
                    llmSelection = .defaultModel
                    customPickerSelection = ""
                    manualModelText = ""
                    customIsManual = false
                    return
                }

                llmSelection = .custom
                customIsManual = newValue == manualEntryTag
                customPickerSelection = customIsManual ? manualEntryTag : newValue
                if !customIsManual {
                    manualModelText = ""
                }
            }
        )
    }

    private var whisperModelOptions: [String] {
        if availableWhisperModels.isEmpty {
            return [TranscriptionService.defaultModel, "openai_whisper-large-v3_turbo", "large-v3", "tiny.en"]
        }
        var models = availableWhisperModels
        if !models.contains(selectedWhisperModel) {
            models.insert(selectedWhisperModel, at: 0)
        }
        return models
    }

    private func shortModelName(_ name: String) -> String {
        if let slash = name.lastIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }

    private func configureInitialLLMSelection() {
        if savedLLMModel == LLMService.defaultModelId {
            llmSelection = .defaultModel
            customPickerSelection = ""
            manualModelText = ""
            customIsManual = false
            return
        }

        llmSelection = .custom
        if Self.otherLLMs.contains(where: { $0.id == savedLLMModel }) {
            customPickerSelection = savedLLMModel
            manualModelText = ""
            customIsManual = false
        } else {
            customPickerSelection = manualEntryTag
            manualModelText = savedLLMModel
            customIsManual = true
        }
    }

    private var resolvedCustomModel: String {
        if customIsManual {
            return manualModelText.trimmingCharacters(in: .whitespaces)
        }
        return customPickerSelection.isEmpty || customPickerSelection == manualEntryTag ? "" : customPickerSelection
    }

    private func scanCachedModels() {
        let fm = FileManager.default
        guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let mlxDir = cachesURL
            .appendingPathComponent("models/mlx-community", isDirectory: true)

        guard let entries = try? fm.contentsOfDirectory(
            at: mlxDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        var found: [(id: String, size: String)] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let configFile = entry.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configFile.path) else { continue }
            let safetensors = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension == "safetensors"
            } ?? []
            guard !safetensors.isEmpty else { continue }

            let folderSize = directorySize(at: entry, fm: fm)
            let sizeStr = ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file)
            found.append((id: entry.lastPathComponent, size: sizeStr))
        }
        cachedModels = found.sorted { $0.id < $1.id }
    }

    private func directorySize(at url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func finishOnboarding() {
        savedWhisperModel = selectedWhisperModel
        savedLLMModel = llmSelection == .custom ? resolvedCustomModel : (llmSelection.modelId ?? LLMService.defaultModelId)
        onComplete()
    }
}

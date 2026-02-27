import SwiftUI

struct OnboardingView: View {
    @Environment(TranscriptionService.self) private var transcriptionService

    @AppStorage("whisperModel") private var savedWhisperModel = TranscriptionService.defaultModel
    @AppStorage("llmModel") private var savedLLMModel = LLMService.defaultModelId

    @State private var step = 0
    @State private var selectedWhisperModel = TranscriptionService.defaultModel
    @State private var llmSelection: LLMSelection = .ram8gb
    @State private var customPickerSelection = ""
    @State private var manualModelText = ""
    @State private var customIsManual = false
    @State private var availableWhisperModels: [String] = []
    @State private var cachedModels: [(id: String, size: String)] = []
    @State private var selectedCachedModel: String = ""

    private static let otherLLMs: [(id: String, size: String)] = [
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

    // MARK: - RAM Detection

    private static var systemRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    private static var recommendedTier: LLMSelection {
        let ram = systemRAMGB
        if ram >= 48 { return .ram48gb }
        if ram >= 16 { return .ram16gb }
        if ram >= 8 { return .ram8gb }
        return .ramLow
    }

    // MARK: - LLM Tiers

    private enum LLMSelection: String, CaseIterable {
        case ramLow = "mlx-community/gemma-3-1b-it-qat-4bit"
        case ram8gb = "mlx-community/Qwen3-4B-4bit"
        case ram16gb = "mlx-community/Qwen3-8B-4bit"
        case ram48gb = "mlx-community/Qwen3-14B-4bit"
        case custom = "_custom_"

        var displayName: String {
            switch self {
            case .ramLow: "Gemma 3 1B"
            case .ram8gb: "Qwen 3 4B"
            case .ram16gb: "Qwen 3 8B"
            case .ram48gb: "Qwen 3 14B"
            case .custom: "Custom HuggingFace Model"
            }
        }

        var ramLabel: String {
            switch self {
            case .ramLow: "Under 8 GB RAM"
            case .ram8gb: "8 GB RAM"
            case .ram16gb: "16 GB RAM"
            case .ram48gb: "48 GB+ RAM"
            case .custom: ""
            }
        }

        var modelSize: String {
            switch self {
            case .ramLow: "~1.6 GB in memory"
            case .ram8gb: "~2.75 GB in memory"
            case .ram16gb: "~5 GB in memory"
            case .ram48gb: "~8.5 GB in memory"
            case .custom: ""
            }
        }

        var note: String {
            switch self {
            case .ramLow:
                "Extremely fast. Genuinely useful for quick Q&A, summarization, and simple tasks."
            case .ram8gb:
                "Matches older 7B models despite being half the size. The /think toggle lets you switch between fast responses and deeper chain-of-thought reasoning."
            case .ram16gb:
                "Major step up in quality — handles complex coding, nuanced writing, and multi-step reasoning well. Leaves generous room for long context."
            case .ram48gb:
                "Where local AI starts rivaling cloud APIs. Expert-level reasoning, serious code generation, nuanced creative writing."
            case .custom: ""
            }
        }

        var badgeColor: Color {
            switch self {
            case .ramLow: Color.mint.opacity(0.15)
            case .ram8gb: Color.green.opacity(0.15)
            case .ram16gb: Color.accentColor.opacity(0.15)
            case .ram48gb: Color.orange.opacity(0.15)
            case .custom: .clear
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
        .onAppear {
            llmSelection = Self.recommendedTier
        }
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
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Chat Model")
                .font(.title2.weight(.semibold))

            VStack(spacing: 2) {
                Text("Pick a model that fits your Mac.")
                    .foregroundStyle(.secondary)
                Text("Detected \(Self.systemRAMGB) GB RAM — recommended tier is pre-selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                ForEach(LLMSelection.allCases, id: \.self) { option in
                    llmOptionRow(option)
                }

                if llmSelection == .custom {
                    VStack(spacing: 8) {
                        Picker("Select a model", selection: $customPickerSelection) {
                            Text("Choose a model…").tag("")
                            ForEach(Self.otherLLMs, id: \.id) { model in
                                Text("\(shortModelName(model.id))  (\(model.size))").tag(model.id)
                            }
                            Divider()
                            Text("Enter manually…").tag("_manual_")
                        }
                        .labelsHidden()
                        .onChange(of: customPickerSelection) {
                            customIsManual = customPickerSelection == "_manual_"
                        }

                        if customIsManual {
                            TextField("mlx-community/model-name", text: $manualModelText)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }
                    }
                    .padding(.leading, 28)
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
                .disabled(llmSelection == .custom && resolvedCustomModel.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func llmOptionRow(_ option: LLMSelection) -> some View {
        let isRecommended = option == Self.recommendedTier

        return HStack(spacing: 4) {
            Button {
                llmSelection = option
            } label: {
                HStack {
                    Image(systemName: llmSelection == option ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(llmSelection == option ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(option.displayName)
                                .font(.callout.weight(.medium))
                            if !option.ramLabel.isEmpty {
                                Text(option.ramLabel)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(option.badgeColor, in: Capsule())
                            }
                            if isRecommended {
                                Text("Recommended for you")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                        if !option.modelSize.isEmpty {
                            Text("\(option.rawValue) — \(option.modelSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !option.note.isEmpty {
                InfoButton(text: option.note)
            }
        }
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

    private var resolvedCustomModel: String {
        if customIsManual {
            return manualModelText.trimmingCharacters(in: .whitespaces)
        }
        return customPickerSelection.isEmpty || customPickerSelection == "_manual_" ? "" : customPickerSelection
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
        savedLLMModel = llmSelection == .custom ? resolvedCustomModel : llmSelection.rawValue
        onComplete()
    }
}

// MARK: - Info Button with Popover

private struct InfoButton: View {
    let text: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            Text(text)
                .font(.caption)
                .padding(10)
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

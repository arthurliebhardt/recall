import SwiftUI

struct ModelLoadingOverlay: View {
    let whisperState: TranscriptionService.ModelState
    let llmState: LLMService.ModelState
    var diarizationState: DiarizationService.ModelState = .notLoaded

    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Preparing Models")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 16) {
                    ModelRow(
                        icon: "waveform",
                        name: "Whisper",
                        detail: whisperDetail,
                        progress: whisperProgress,
                        isLoading: whisperIsLoading,
                        isDone: whisperState.isReady,
                        isError: whisperIsError
                    )

                    ModelRow(
                        icon: "brain",
                        name: "LLM",
                        detail: llmDetail,
                        progress: llmProgress,
                        isLoading: llmIsLoading,
                        isDone: llmState.isReady,
                        isError: llmIsError
                    )

                    ModelRow(
                        icon: "person.2",
                        name: "Diarization",
                        detail: diarizationDetail,
                        progress: nil,
                        isLoading: diarizationIsLoading,
                        isDone: diarizationState.isReady,
                        isError: diarizationIsError
                    )
                }

                if elapsedSeconds > 0 {
                    Text("Elapsed: \(formattedElapsed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(32)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20, y: 10)
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Timer

    private func startTimer() {
        elapsedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedSeconds += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private var formattedElapsed: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }

    // MARK: - Whisper helpers

    private var whisperDetail: String {
        switch whisperState {
        case .notLoaded: return "Waiting..."
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading into memory..."
        case .loaded(let m): return shortModelName(m)
        case .error(let e): return e
        }
    }

    private var whisperProgress: Double? {
        if case .downloading(let p) = whisperState { return p }
        return nil
    }

    private var whisperIsLoading: Bool {
        if case .loading = whisperState { return true }
        if case .downloading = whisperState { return true }
        return false
    }

    private var whisperIsError: Bool {
        if case .error = whisperState { return true }
        return false
    }

    // MARK: - LLM helpers

    private var llmDetail: String {
        switch llmState {
        case .notLoaded: return "Waiting..."
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading into memory..."
        case .loaded(let m): return shortModelName(m)
        case .error(let e): return e
        }
    }

    private var llmProgress: Double? {
        if case .downloading(let p) = llmState { return p }
        return nil
    }

    private var llmIsLoading: Bool {
        if case .loading = llmState { return true }
        if case .downloading = llmState { return true }
        return false
    }

    private var llmIsError: Bool {
        if case .error = llmState { return true }
        return false
    }

    // MARK: - Diarization helpers

    private var diarizationDetail: String {
        switch diarizationState {
        case .notLoaded: return "Waiting..."
        case .downloading: return "Downloading models..."
        case .loading: return "Loading into memory..."
        case .loaded: return "Ready"
        case .error(let e): return e
        }
    }

    private var diarizationIsLoading: Bool {
        if case .downloading = diarizationState { return true }
        if case .loading = diarizationState { return true }
        return false
    }

    private var diarizationIsError: Bool {
        if case .error = diarizationState { return true }
        return false
    }

    // MARK: - Util

    private func shortModelName(_ name: String) -> String {
        // "mlx-community/Qwen3-4B-4bit" → "Qwen3-4B-4bit"
        if let slash = name.lastIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }
}

// MARK: - Row

private struct ModelRow: View {
    let icon: String
    let name: String
    let detail: String
    let progress: Double?
    let isLoading: Bool
    let isDone: Bool
    let isError: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 36, height: 36)

                if isLoading && progress == nil {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.callout.weight(.medium))

                if let progress {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var statusIcon: String {
        if isDone { return "checkmark" }
        if isError { return "xmark" }
        if isLoading && progress != nil { return icon }
        return icon
    }

    private var backgroundColor: Color {
        if isDone { return .green.opacity(0.15) }
        if isError { return .red.opacity(0.15) }
        return .secondary.opacity(0.1)
    }

    private var iconColor: Color {
        if isDone { return .green }
        if isError { return .red }
        return .secondary
    }
}

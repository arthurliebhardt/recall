import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct RecallApp: App {

    @State private var transcriptionService = TranscriptionService()
    @State private var audioExtractionService = AudioExtractionService()
    @State private var llmService = LLMService()
    @State private var diarizationService = DiarizationService()
    @State private var youTubeService = YouTubeService()
    @State private var transcriptionViewModel: TranscriptionViewModel
    @State private var chatViewModel: ChatViewModel

    let modelContainer: ModelContainer

    init() {
#if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
#endif

        let ts = TranscriptionService()
        let aes = AudioExtractionService()
        let llm = LLMService()
        let ds = DiarizationService()
        let yt = YouTubeService()
        _transcriptionService = State(initialValue: ts)
        _audioExtractionService = State(initialValue: aes)
        _llmService = State(initialValue: llm)
        _diarizationService = State(initialValue: ds)
        _youTubeService = State(initialValue: yt)
        _transcriptionViewModel = State(initialValue: TranscriptionViewModel(
            transcriptionService: ts,
            audioExtractionService: aes,
            diarizationService: ds,
            youTubeService: yt
        ))
        _chatViewModel = State(initialValue: ChatViewModel(llmService: llm))

        // Create model container, wiping old store if schema changed
        do {
            modelContainer = try ModelContainer(for: TranscriptionRecord.self)
        } catch {
            // Schema migration failed — delete old store and retry
            print("[SwiftData] Migration failed: \(error). Deleting old store...")
            let url = URL.applicationSupportDirectory
                .appending(path: "default.store")
            try? FileManager.default.removeItem(at: url)
            // Also remove WAL/SHM files
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL.applicationSupportDirectory
                    .appending(path: "default.store\(suffix)")
                try? FileManager.default.removeItem(at: sidecar)
            }
            modelContainer = try! ModelContainer(for: TranscriptionRecord.self)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(transcriptionService)
                .environment(audioExtractionService)
                .environment(llmService)
                .environment(diarizationService)
                .environment(transcriptionViewModel)
                .environment(chatViewModel)
        }
        .defaultSize(width: 1100, height: 650)
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
                .environment(transcriptionService)
                .environment(llmService)
        }
    }
}

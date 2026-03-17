import Foundation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {

    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false
    var inputText = ""

    private let llmService: LLMService
    private var currentTask: Task<Void, Never>?
    private var activeRecordId: UUID?
    private weak var modelContext: ModelContext?

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && llmService.modelState.isReady
            && activeRecordId != nil
    }

    /// Load chat for a specific transcription record
    func loadChat(for record: TranscriptionRecord, modelContext: ModelContext) {
        // Don't reload if already showing this record's chat
        if activeRecordId == record.id { return }

        cancelGeneration()
        self.modelContext = modelContext
        activeRecordId = record.id
        messages = record.chatMessages
        inputText = ""
    }

    /// Clear chat for the current record
    func clearChat(for record: TranscriptionRecord, modelContext: ModelContext) {
        cancelGeneration()
        messages = []
        inputText = ""
        record.chatMessages = []
        try? modelContext.save()
    }

    /// Send a message and stream the LLM response
    func sendMessage(record: TranscriptionRecord) {
        let userText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        inputText = ""
        let userMessage = ChatMessage(role: .user, content: userText)
        messages.append(userMessage)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        // Save user message immediately
        record.chatMessages = messages
        try? modelContext?.save()

        isGenerating = true

        currentTask = Task {
            do {
                let systemPrompt = buildSystemPrompt(transcriptionText: record.fullText)
                let conversationMessages = messages.dropLast().map { msg -> (role: String, content: String) in
                    (role: msg.role.rawValue, content: msg.content)
                }

                let stream = llmService.streamResponse(
                    systemPrompt: systemPrompt,
                    messages: Array(conversationMessages)
                )

                var first = true
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    if first {
                        messages[assistantIndex].content = chunk
                        first = false
                    } else {
                        messages[assistantIndex].content += chunk
                    }
                }
            } catch {
                if !Task.isCancelled {
                    messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                }
            }

            // Save completed response
            record.chatMessages = messages
            try? modelContext?.save()

            isGenerating = false
        }
    }

    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    private func buildSystemPrompt(transcriptionText: String) -> String {
        """
        You are a helpful assistant that answers questions about a transcribed audio/video file. \
        Below is the full transcription. Use it to answer the user's questions accurately and concisely. \
        If the answer is not in the transcription, say so.

        --- TRANSCRIPTION ---
        \(transcriptionText)
        --- END TRANSCRIPTION ---
        """
    }
}

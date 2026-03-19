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
    private var currentGenerationId: UUID?
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

        cancelGeneration(discardResponse: true)
        self.modelContext = modelContext
        activeRecordId = record.id
        messages = record.chatMessages
        inputText = ""
    }

    /// Clear chat for the current record
    func clearChat(for record: TranscriptionRecord, modelContext: ModelContext) {
        cancelGeneration(discardResponse: true)
        messages = []
        inputText = ""
        record.chatMessages = []
        try? modelContext.save()
    }

    /// Send a message and stream the LLM response
    func sendMessage(record: TranscriptionRecord) {
        let userText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }
        let priorMessages = messages
        let recordId = record.id
        let modelContext = self.modelContext
        let generationId = UUID()

        inputText = ""
        let userMessage = ChatMessage(role: .user, content: userText)
        messages.append(userMessage)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantMessageId = assistantMessage.id
        var workingMessages = messages

        // Save user message immediately
        record.chatMessages = workingMessages
        try? modelContext?.save()

        isGenerating = true
        currentGenerationId = generationId

        currentTask = Task {
            do {
                let systemPrompt = buildSystemPrompt(transcriptionText: record.fullText)
                let stream = try llmService.streamResponse(
                    recordId: recordId,
                    systemPrompt: systemPrompt,
                    history: priorMessages,
                    prompt: userText
                )

                for try await chunk in stream {
                    if Task.isCancelled { break }
                    if let assistantIndex = workingMessages.firstIndex(where: { $0.id == assistantMessageId }) {
                        workingMessages[assistantIndex].content += chunk
                    }
                    if currentGenerationId == generationId && activeRecordId == recordId {
                        messages = workingMessages
                    }
                }
            } catch {
                if !Task.isCancelled {
                    if let assistantIndex = workingMessages.firstIndex(where: { $0.id == assistantMessageId }) {
                        workingMessages[assistantIndex].content = "Error: \(error.localizedDescription)"
                    }
                }
            }

            let shouldCommit = currentGenerationId == generationId || currentGenerationId == nil

            if shouldCommit && activeRecordId == recordId {
                messages = workingMessages
            }

            // Save completed or cancelled response
            if shouldCommit {
                record.chatMessages = workingMessages
                try? modelContext?.save()
            }

            if currentGenerationId == generationId && activeRecordId == recordId {
                isGenerating = false
            }
            if currentGenerationId == generationId {
                currentGenerationId = nil
                currentTask = nil
            }
        }
    }

    func cancelGeneration() {
        cancelGeneration(discardResponse: false)
    }

    private func cancelGeneration(discardResponse: Bool) {
        currentTask?.cancel()
        if let activeRecordId {
            llmService.resetSession(for: activeRecordId)
        }
        currentGenerationId = discardResponse ? UUID() : nil
        currentTask = nil
        isGenerating = false
    }

    private func buildSystemPrompt(transcriptionText: String) -> String {
        """
        You are a helpful assistant that answers questions about a transcribed audio/video file. \
        Below is the full transcription. Use it to answer the user's questions accurately and concisely. \
        Answer directly and keep responses brief unless the user asks for more detail. \
        If the answer is not in the transcription, say so. \
        Do not use <think> tags or expose chain-of-thought.

        --- TRANSCRIPTION ---
        \(transcriptionText)
        --- END TRANSCRIPTION ---
        """
    }
}

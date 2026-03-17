import Foundation
import MLXLLM
import MLXLMCommon

@Observable
@MainActor
final class LLMService {

    enum LLMError: LocalizedError {
        case modelNotLoaded
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "LLM model is not loaded."
            case .generationFailed(let reason):
                return "Generation failed: \(reason)"
            }
        }
    }

    enum ModelState: Equatable {
        case notLoaded
        case downloading(Double)
        case loading
        case loaded(String)
        case error(String)

        var isReady: Bool {
            if case .loaded = self { return true }
            return false
        }

        var modelName: String? {
            if case .loaded(let name) = self { return name }
            return nil
        }
    }

    static let defaultModelId = "mlx-community/Qwen3-8B-4bit"

    private(set) var modelState: ModelState = .notLoaded
    private(set) var isGenerating = false

    private var modelContainer: ModelContainer?

    // MARK: - Model Management

    func loadModel(_ modelId: String = defaultModelId) async {
        modelState = .downloading(0)

        do {
            let configuration = ModelConfiguration(id: modelId)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelState = .downloading(progress.fractionCompleted)
                }
            }
            self.modelContainer = container
            modelState = .loaded(modelId)
        } catch {
            modelState = .error(error.localizedDescription)
        }
    }

    func unloadModel() {
        modelContainer = nil
        modelState = .notLoaded
    }

    // MARK: - Generation

    /// Generate a streaming response given a system prompt and conversation messages.
    func streamResponse(
        systemPrompt: String,
        messages: [(role: String, content: String)]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let modelContainer else {
                    continuation.finish(throwing: LLMError.modelNotLoaded)
                    return
                }

                self.isGenerating = true
                defer { self.isGenerating = false }

                do {
                    var chatMessages: [Chat.Message] = [.system(systemPrompt)]
                    for msg in messages {
                        switch msg.role {
                        case "user":
                            chatMessages.append(.user(msg.content))
                        case "assistant":
                            chatMessages.append(.assistant(msg.content))
                        default:
                            break
                        }
                    }

                    let userInput = UserInput(chat: chatMessages)
                    let lmInput = try await modelContainer.prepare(input: userInput)
                    let parameters = GenerateParameters(
                        maxTokens: 2048,
                        temperature: 0.6
                    )

                    let stream = try await modelContainer.generate(
                        input: lmInput,
                        parameters: parameters
                    )

                    for await generation in stream {
                        if let text = generation.chunk {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

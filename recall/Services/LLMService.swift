import Foundation
import os
import MLXLLM
import MLXLMCommon

private let logger = Logger(subsystem: "com.summarizecontent.app", category: "LLM")

@Observable
@MainActor
final class LLMService {
    struct ModelRecommendation: Sendable {
        let recommendedRAM: String
    }

    nonisolated private static let legacyModelFallbacks: [String: String] = [
        "mlx-community/Qwen3.5-9B-OptiQ-4bit": "mlx-community/Qwen3-4B-4bit"
    ]
    nonisolated private static let previousDefaultModelId = "mlx-community/Qwen3-8B-4bit"
    nonisolated private static let knownRecommendations: [String: ModelRecommendation] = [
        "mlx-community/Qwen3-4B-4bit": .init(recommendedRAM: "16 GB"),
        "mlx-community/Llama-3.2-3B-Instruct-4bit": .init(recommendedRAM: "16 GB"),
        "mlx-community/Phi-4-mini-instruct-4bit": .init(recommendedRAM: "16 GB"),
        "mlx-community/gemma-3-4b-it-qat-4bit": .init(recommendedRAM: "16 GB"),
        "mlx-community/Mistral-7B-Instruct-v0.3-4bit": .init(recommendedRAM: "24 GB"),
        "mlx-community/Qwen3-8B-4bit": .init(recommendedRAM: "24 GB"),
        "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": .init(recommendedRAM: "24 GB"),
        "mlx-community/GLM-4.7-4bit": .init(recommendedRAM: "24 GB"),
        "mlx-community/Qwen3-14B-4bit": .init(recommendedRAM: "32 GB"),
        "mlx-community/Qwen3-30B-A3B-4bit": .init(recommendedRAM: "64 GB"),
        "mlx-community/DeepSeek-V3.1-4bit": .init(recommendedRAM: "128 GB"),
        "mlx-community/Llama-3.3-70B-Instruct-4bit": .init(recommendedRAM: "128 GB"),
    ]

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
        case preparing(Double?, String)
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

    nonisolated static let defaultModelId = "mlx-community/Qwen3-4B-4bit"

    nonisolated static func normalizeModelId(_ modelId: String) -> String {
        legacyModelFallbacks[modelId] ?? modelId
    }

    nonisolated static func resolvePersistedModelId(_ modelId: String) -> String {
        let normalizedModelId = normalizeModelId(modelId)
        if normalizedModelId == previousDefaultModelId {
            return isModelCached(defaultModelId) ? defaultModelId : previousDefaultModelId
        }
        return normalizedModelId
    }

    nonisolated static func recommendedRAM(for modelId: String, sizeBytes: Int64? = nil) -> String {
        let normalizedModelId = normalizeModelId(modelId)
        if let recommendation = knownRecommendations[normalizedModelId] {
            return recommendation.recommendedRAM
        }
        if let sizeBytes {
            return estimatedRecommendedRAM(forModelSize: sizeBytes)
        }
        return "16+ GB"
    }

    nonisolated private static func isModelCached(_ modelId: String) -> Bool {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }

        let modelDirectoryName = modelId
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? modelId
        let modelDirectory = cachesDirectory
            .appendingPathComponent("models/mlx-community", isDirectory: true)
            .appendingPathComponent(modelDirectoryName, isDirectory: true)

        let configFile = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return false
        }

        let modelFiles = (try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return modelFiles.contains { $0.pathExtension == "safetensors" }
    }

    nonisolated private static func estimatedRecommendedRAM(forModelSize sizeBytes: Int64) -> String {
        let sizeGB = Double(sizeBytes) / 1_073_741_824
        switch sizeGB {
        case ..<3.5:
            return "16 GB"
        case ..<6.5:
            return "24 GB"
        case ..<10.5:
            return "32 GB"
        case ..<20:
            return "64 GB"
        case ..<44:
            return "128 GB"
        default:
            return "192 GB"
        }
    }

    private(set) var modelState: ModelState = .notLoaded
    private(set) var isGenerating = false

    private var modelContainer: ModelContainer?
    private var chatSessions: [UUID: ChatSession] = [:]
    private let chatGenerationParameters = GenerateParameters(
        maxTokens: 2048,
        temperature: 0.6
    )

    // MARK: - Model Management

    func loadModel(_ modelId: String = defaultModelId) async {
        let resolvedModelId = Self.normalizeModelId(modelId)
        if resolvedModelId != modelId {
            logger.notice("[MLX] Falling back from incompatible model \(modelId) to \(resolvedModelId)")
        }

        modelState = .downloading(0)

        do {
            try await MLXMetalBootstrap.ensureSwiftPMMetallibIfNeeded { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.modelState = .preparing(status.fractionCompleted, status.message)
                }
            }
            modelState = .downloading(0)
            let configuration = ModelConfiguration(id: resolvedModelId)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelState = .downloading(progress.fractionCompleted)
                }
            }
            self.modelContainer = container
            chatSessions.removeAll()
            modelState = .loaded(resolvedModelId)
        } catch {
            modelState = .error(error.localizedDescription)
        }
    }

    func unloadModel() {
        modelContainer = nil
        chatSessions.removeAll()
        modelState = .notLoaded
    }

    func resetSession(for recordId: UUID) {
        chatSessions.removeValue(forKey: recordId)
    }

    // MARK: - Generation

    /// Generate a streaming response using a cached chat session per record.
    func streamResponse(
        recordId: UUID,
        systemPrompt: String,
        history: [ChatMessage],
        prompt: String
    ) throws -> AsyncThrowingStream<String, Error> {
        guard let modelContainer else {
            throw LLMError.modelNotLoaded
        }

        let session = session(
            for: recordId,
            systemPrompt: systemPrompt,
            history: history,
            modelContainer: modelContainer
        )

        isGenerating = true
        let baseStream = session.streamResponse(to: prompt)

        return AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) { [weak self] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.isGenerating = false
                    }
                }

                do {
                    for try await chunk in baseStream {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func session(
        for recordId: UUID,
        systemPrompt: String,
        history: [ChatMessage],
        modelContainer: ModelContainer
    ) -> ChatSession {
        if let existing = chatSessions[recordId] {
            return existing
        }

        let restoredHistory = history.compactMap(Self.chatMessage(from:))
        let session = ChatSession(
            modelContainer,
            instructions: systemPrompt,
            history: restoredHistory,
            generateParameters: chatGenerationParameters
        )
        chatSessions[recordId] = session
        return session
    }

    private static func chatMessage(from message: ChatMessage) -> Chat.Message? {
        switch message.role {
        case .user:
            return .user(message.content)
        case .assistant:
            return .assistant(message.content)
        }
    }
}

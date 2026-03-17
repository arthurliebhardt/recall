import SwiftUI

struct ChatView: View {
    let record: TranscriptionRecord

    @Environment(ChatViewModel.self) private var chatVM
    @Environment(LLMService.self) private var llmService
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var chatVM = chatVM

        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                if !chatVM.messages.isEmpty {
                    Button("Clear") {
                        chatVM.clearChat(for: record, modelContext: modelContext)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Model status bar
            if !llmService.modelState.isReady {
                ModelStatusBar(state: llmService.modelState)
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatVM.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: chatVM.messages.count) {
                    if let lastId = chatVM.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chatVM.messages.last?.content) {
                    if let lastId = chatVM.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input
            ChatInputView(
                text: $chatVM.inputText,
                isGenerating: chatVM.isGenerating,
                canSend: chatVM.canSend,
                onSend: {
                    chatVM.sendMessage(record: record)
                },
                onCancel: {
                    chatVM.cancelGeneration()
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if chatVM.messages.isEmpty && llmService.modelState.isReady {
                ContentUnavailableView(
                    "Ask a Question",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Ask anything about this transcription.")
                )
            }
        }
        .onAppear {
            chatVM.loadChat(for: record, modelContext: modelContext)
        }
        .onChange(of: record.id) {
            chatVM.loadChat(for: record, modelContext: modelContext)
        }
    }
}

private struct ModelStatusBar: View {
    let state: LLMService.ModelState

    var body: some View {
        HStack {
            switch state {
            case .notLoaded:
                Label("LLM not loaded", systemImage: "exclamationmark.triangle")
                Spacer()
                Text("Open Settings to load a model")
                    .font(.caption)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 100)
                Text("Downloading LLM... \(Int(progress * 100))%")
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Loading LLM...")
            case .loaded:
                EmptyView()
            case .error(let msg):
                Label("LLM error: \(msg)", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

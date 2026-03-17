import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if message.content.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                } else if message.role == .assistant {
                    AssistantContentView(content: message.content)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Color.accentColor.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Assistant content with think blocks + markdown

private struct AssistantContentView: View {
    let content: String

    var body: some View {
        let parts = Self.parse(content)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .think(let text):
                    ThinkBlockView(content: text)
                case .text(let text):
                    MarkdownTextView(content: text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.secondary.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Parser

    enum ContentPart {
        case think(String)
        case text(String)
    }

    static func parse(_ content: String) -> [ContentPart] {
        var parts: [ContentPart] = []
        var remaining = content[...]

        while let openRange = remaining.range(of: "<think>") {
            // Text before <think>
            let before = String(remaining[remaining.startIndex..<openRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                parts.append(.text(before))
            }

            remaining = remaining[openRange.upperBound...]

            if let closeRange = remaining.range(of: "</think>") {
                let thinkText = String(remaining[remaining.startIndex..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !thinkText.isEmpty {
                    parts.append(.think(thinkText))
                }
                remaining = remaining[closeRange.upperBound...]
            } else {
                // Unclosed <think> — treat rest as thinking (streaming in progress)
                let thinkText = String(remaining)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !thinkText.isEmpty {
                    parts.append(.think(thinkText))
                }
                remaining = remaining[remaining.endIndex...]
            }
        }

        // Remaining text after last </think>
        let trailing = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            parts.append(.text(trailing))
        }

        return parts
    }
}

// MARK: - Collapsible think block

private struct ThinkBlockView: View {
    let content: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

// MARK: - Markdown text rendering

private struct MarkdownTextView: View {
    let content: String

    var body: some View {
        Text(attributedContent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedContent: AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(content)
    }
}

import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var conversationID: UUID?
    @State private var draft = ""
    @State private var sendCount = 0
    @FocusState private var inputFocused: Bool

    init(conversationID: UUID?) {
        _conversationID = State(initialValue: conversationID)
    }

    private var conversation: Conversation? {
        guard let conversationID else { return nil }
        return state.conversations.first { $0.id == conversationID }
    }
    private var model: String { conversation?.model ?? state.defaultModel }
    private var isStreaming: Bool { conversationID != nil && state.streamingConversation == conversationID }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.streamingConversation == nil
    }

    var body: some View {
        Group {
            if let conversation, !conversation.messages.isEmpty {
                messages(conversation)
            } else {
                EmptyChatView(model: model) { suggestion in
                    draft = suggestion
                    inputFocused = true
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModelMenu(selection: model) { state.setModel($0, for: conversationID) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
    }

    private func messages(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(conversation.messages) { message in
                        MessageRow(
                            message: message,
                            conversationID: conversation.id,
                            isStreaming: isStreaming && message.id == conversation.messages.last?.id
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.messages.last?.content) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                if isStreaming { stop() } else { send() }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canSend || isStreaming ? Color.accentColor : Color(.systemGray3)))
            }
            .disabled(!canSend && !isStreaming)
            .accessibilityLabel(isStreaming ? "Stop" : "Send")
            .padding(.bottom, 4)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !model.isEmpty else {
            state.show("Pick a model first")
            return
        }
        draft = ""
        conversationID = state.send(text, in: conversationID)
        sendCount += 1
    }

    private func stop() {
        state.stop()
    }
}

// MARK: - Empty state

private struct EmptyChatView: View {
    let model: String
    let pick: (String) -> Void
    private let suggestions = ["Plan my day", "Explain something simply", "Help me write a message", "Brainstorm ideas"]

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image("Logo")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text("How can I help?").font(.title2.weight(.semibold))
            Group {
                if model.isEmpty { Text("Choose a model above") } else { Text("Talking to **\(model)**") }
            }
            .foregroundStyle(.secondary)
            FlowChips(items: suggestions, pick: pick).padding(.top, 8)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

private struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(items[i..<min(i + 2, items.count)], id: \.self) { item in
                        Button(item) { pick(item) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(Color.primary)
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

// MARK: - Messages

struct MessageRow: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    let conversationID: UUID
    let isStreaming: Bool

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if message.content.isEmpty && isStreaming {
                    Image(systemName: "ellipsis")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .accessibilityLabel("Thinking")
                } else {
                    MarkdownText(message.content)
                }
                if !isStreaming && message.error == nil && !message.content.isEmpty {
                    actions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 20) {
            Button {
                UIPasteboard.general.string = message.content
                state.show("Copied")
            } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy")
            Button { state.speak(message.content) } label: { Image(systemName: "speaker.wave.2") }
                .accessibilityLabel("Read aloud")
            Button { Task { await state.rate(message.id, in: conversationID, value: 1) } } label: {
                Image(systemName: message.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .accessibilityLabel("Good reply")
            Button { Task { await state.rate(message.id, in: conversationID, value: -1) } } label: {
                Image(systemName: message.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .accessibilityLabel("Bad reply")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: message.rating)
    }
}

/// Renders replies: ``` code blocks in monospaced boxes, inline markdown (bold, italics, `code`, links) elsewhere.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    enum Block {
        case text(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(Self.inline(s))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    static func blocks(_ s: String) -> [Block] {
        s.components(separatedBy: "```").enumerated().compactMap { (pair) -> Block? in
            let (i, part) = pair
            if i % 2 == 1 {
                var code = part
                // Drop a language tag line such as "python" or "c++".
                if let nl = code.firstIndex(of: "\n"),
                   code[..<nl].allSatisfy({ $0.isLetter || $0.isNumber || "+#._-".contains($0) }) {
                    code = String(code[code.index(after: nl)...])
                }
                code = code.trimmingCharacters(in: .newlines)
                return code.isEmpty ? nil : .code(code)
            }
            let t = part.trimmingCharacters(in: .newlines)
            return t.isEmpty ? nil : .text(t)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Model picker

struct ModelMenu: View {
    @Environment(AppState.self) private var state
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            section("Your models", state.models.filter(\.isCustom))
            section("Base models", state.models.filter(\.isBase))
            section("Pinned versions", state.models.filter(\.isPinnedVersion))
            Divider()
            Button {
                Task { await state.refreshModels() }
            } label: {
                Label("Refresh list", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? "Choose model" : selection)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Model: \(selection)")
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ModelEntry]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { m in
                    Button {
                        onSelect(m.id)
                    } label: {
                        if m.id == selection {
                            Label(m.id, systemImage: "checkmark")
                        } else {
                            Text(m.id)
                        }
                    }
                }
            }
        }
    }
}

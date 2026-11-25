import SwiftUI

enum Route: Hashable {
    case chat(UUID?)
}

struct ConversationsView: View {
    @Environment(AppState.self) private var state
    @State private var path: [Route] = []
    @State private var showSettings = false
    @State private var showModels = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if state.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Talk to your own models, running on your own server.")
                    } actions: {
                        Button("New chat") { path.append(.chat(nil)) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(state.conversations) { conversation in
                            NavigationLink(value: Route.chat(conversation.id)) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete { state.deleteConversations(at: $0) }
                    }
                    .listStyle(.plain)
                    .refreshable { await state.refreshModels() }
                }
            }
            .navigationTitle("JARVIS")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                    if state.isAdmin {
                        Button { showModels = true } label: { Image(systemName: "cpu") }
                            .accessibilityLabel("My models")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.chat(nil)) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let id): ChatView(conversationID: id)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(state).toastOverlay()
        }
        .sheet(isPresented: $showModels) {
            ModelsView().environment(state).toastOverlay()
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(conversation.model) · \(conversation.updated.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        conversation.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.content
            .replacingOccurrences(of: "\n", with: " ") ?? ""
    }
}

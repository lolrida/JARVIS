import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase { case restoring, signedOut, signedIn }

    var phase: Phase = .restoring
    private(set) var serverURL: URL?
    private(set) var apiKey: String?
    private(set) var me: WhoAmI?
    var conversations: [Conversation] = []
    var models: [ModelEntry] = []
    private(set) var streamingConversation: UUID?
    private(set) var toast: String?

    // Settings, persisted in UserDefaults.
    private var storedDefaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
    private var storedReadAloud = UserDefaults.standard.bool(forKey: "readAloud")
    private var storedTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double

    var defaultModel: String {
        get { storedDefaultModel }
        set { storedDefaultModel = newValue; UserDefaults.standard.set(newValue, forKey: "defaultModel") }
    }
    var readAloud: Bool {
        get { storedReadAloud }
        set { storedReadAloud = newValue; UserDefaults.standard.set(newValue, forKey: "readAloud") }
    }
    /// nil means "use the model's own setting".
    var temperature: Double? {
        get { storedTemperature }
        set {
            storedTemperature = newValue
            if let newValue { UserDefaults.standard.set(newValue, forKey: "temperature") }
            else { UserDefaults.standard.removeObject(forKey: "temperature") }
        }
    }

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private let speaker = AVSpeechSynthesizer()

    var api: APIClient? {
        guard let serverURL, let apiKey else { return nil }
        return APIClient(baseURL: serverURL, key: apiKey)
    }
    var isAdmin: Bool { me?.isAdmin == true }

    init() {
        serverURL = UserDefaults.standard.url(forKey: "serverURL")
        apiKey = Keychain.load(account: "default")
        conversations = Self.loadConversations()
    }

    // MARK: Sign in / out

    func restore() async {
        guard let api else { phase = .signedOut; return }
        do {
            me = try await api.whoami()
            phase = .signedIn
            await refreshModels()
        } catch APIError.unauthorized {
            signOut()
        } catch {
            // Server unreachable: still open the app so saved chats can be read.
            phase = .signedIn
            show("Can't reach your server right now")
        }
    }

    func signIn(server: String, key: String) async throws {
        guard let url = Self.normalize(server) else { throw APIError.badURL }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        me = try await APIClient(baseURL: url, key: key).whoami()
        serverURL = url
        apiKey = key
        UserDefaults.standard.set(url, forKey: "serverURL")
        Keychain.save(key, account: "default")
        phase = .signedIn
        await refreshModels()
    }

    func signOut() {
        stop()
        Keychain.delete(account: "default")
        apiKey = nil
        me = nil
        models = []
        phase = .signedOut
    }

    /// Accepts "192.168.1.20:8000", "https://box.tailnet.ts.net", or a pasted ".../app" link.
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = (s.contains(".ts.net") ? "https://" : "http://") + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/app") { s.removeLast(4) }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    func engineOnline() async -> Bool? {
        try? await api?.health().engine
    }

    // MARK: Models

    func refreshModels() async {
        guard let api else { return }
        do {
            models = try await api.models()
            if defaultModel.isEmpty || !models.contains(where: { $0.id == defaultModel }) {
                defaultModel = (models.first(where: \.isCustom) ?? models.first)?.id ?? ""
            }
        } catch {
            show(error.localizedDescription)
        }
    }

    func setModel(_ model: String, for conversationID: UUID?) {
        defaultModel = model
        if let id = conversationID, let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].model = model
            save()
        }
    }

    // MARK: Chatting

    /// Sends a message and streams the reply in. Returns the conversation's id (new chats get one here).
    @discardableResult
    func send(_ text: String, in conversationID: UUID?) -> UUID {
        var conversation: Conversation
        if let id = conversationID, let i = conversations.firstIndex(where: { $0.id == id }) {
            conversation = conversations.remove(at: i)
        } else {
            conversation = Conversation(title: String(text.prefix(48)), model: defaultModel)
        }
        conversation.messages.append(ChatMessage(role: "user", content: text))
        let history = conversation.messages
            .filter { $0.error == nil }
            .map { ["role": $0.role, "content": $0.content] }
        let reply = ChatMessage(role: "assistant", content: "", model: conversation.model)
        conversation.messages.append(reply)
        conversation.updated = Date()
        conversations.insert(conversation, at: 0)
        save()

        let convID = conversation.id, replyID = reply.id, model = conversation.model
        guard let api else {
            finishReply(convID, replyID, failure: "Not connected to a server.")
            return convID
        }
        streamingConversation = convID
        let temperature = self.temperature
        streamTask = Task { [weak self] in
            var failure: String?
            do {
                for try await piece in api.streamChat(model: model, messages: history, temperature: temperature) {
                    self?.updateMessage(convID, replyID) { $0.content += piece }
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            self?.finishReply(convID, replyID, failure: failure)
        }
        return convID
    }

    func stop() {
        streamTask?.cancel()
    }

    private func finishReply(_ convID: UUID, _ replyID: UUID, failure: String?) {
        var finalText = ""
        updateMessage(convID, replyID) { m in
            if m.content.isEmpty { m.error = failure ?? "Stopped." }
            finalText = m.content
        }
        if failure != nil && !finalText.isEmpty { show(failure!) }
        streamingConversation = nil
        streamTask = nil
        save()
        if readAloud && !finalText.isEmpty { speak(finalText) }
    }

    private func updateMessage(_ convID: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let c = conversations.firstIndex(where: { $0.id == convID }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[c].messages[m])
    }

    /// 👍 / 👎 a reply. Thumbs-up conversations become training data for the model's next version.
    func rate(_ messageID: UUID, in convID: UUID, value: Int) async {
        guard let api,
              let conv = conversations.first(where: { $0.id == convID }),
              let idx = conv.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let messages = conv.messages[...idx]
            .filter { $0.error == nil }
            .map { ["role": $0.role, "content": $0.content] }
        do {
            try await api.feedback(model: conv.messages[idx].model ?? conv.model, messages: messages, rating: value)
            updateMessage(convID, messageID) { $0.rating = value }
            save()
            show(value > 0 ? "Saved to training data" : "Noted")
        } catch {
            show(error.localizedDescription)
        }
    }

    func deleteConversations(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        save()
    }

    func deleteAllConversations() {
        stop()
        conversations = []
        save()
    }

    // MARK: Voice

    func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: Self.plainText(text))
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        speaker.speak(utterance)
    }

    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code) ", options: .regularExpression)
            .replacingOccurrences(of: "[*`#_>]", with: "", options: .regularExpression)
    }

    // MARK: Toasts

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Persistence (chats live only on this phone)

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "conversations.json")
    }

    private static func loadConversations() -> [Conversation] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Conversation].self, from: data)) ?? []
    }

    func save() {
        let keep = Array(conversations.prefix(200))
        guard let data = try? JSONEncoder().encode(keep) else { return }
        try? data.write(to: Self.storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

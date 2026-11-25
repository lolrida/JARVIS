import Foundation

// MARK: - Stored on the phone

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String            // "user" or "assistant"
    var content: String
    var model: String? = nil    // which model wrote an assistant reply
    var rating: Int? = nil      // 1 / -1 once rated
    var error: String? = nil
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var model: String
    var messages: [ChatMessage] = []
    var updated = Date()
}

// MARK: - Server responses (snake_case keys are converted automatically)

struct WhoAmI: Decodable {
    let id: Int
    let name: String
    let isAdmin: Bool
}

struct ModelList: Decodable {
    let data: [ModelEntry]
}

struct ModelEntry: Decodable, Identifiable, Hashable {
    let id: String
    let ownedBy: String

    var isCustom: Bool { ownedBy == "you" && !id.contains("@") }
    var isPinnedVersion: Bool { id.contains("@") }
    var isBase: Bool { ownedBy == "base" }
}

struct AdminModels: Decodable {
    let custom: [CustomModel]
    let base: [BaseModel]
    let engine: Bool
}

struct CustomModel: Decodable, Identifiable {
    let name: String
    let description: String
    let activeVersion: Int?
    let versions: [ModelVersion]
    var id: String { name }
}

struct ModelVersion: Decodable, Identifiable {
    let version: Int
    let base: String?
    let ggufDigest: String?
    let system: String
    let notes: String
    var id: Int { version }
}

struct BaseModel: Decodable, Identifiable {
    let name: String
    let size: Int64
    var id: String { name }
}

struct Health: Decodable {
    let status: String
    let engine: Bool
}

struct PullProgress: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?
    let error: String?
}

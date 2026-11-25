import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case unreachable(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That server address doesn't look right."
        case .unauthorized: return "Your API key was rejected. Sign in again."
        case .unreachable(let why): return "Can't reach your JARVIS server. \(why)"
        case .server(let message): return message
        }
    }
}

/// Talks to a JARVIS server: its OpenAI-compatible API plus the admin API.
struct APIClient {
    let baseURL: URL
    let key: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Endpoints

    func health() async throws -> Health { try await get("health") }
    func whoami() async throws -> WhoAmI { try await get("api/whoami") }
    func models() async throws -> [ModelEntry] { try await get("v1/models", as: ModelList.self).data }
    func adminModels() async throws -> AdminModels { try await get("api/models") }

    func activate(_ name: String, version: Int) async throws {
        _ = try await perform(request("api/models/\(name)/activate", method: "POST", body: ["version": version]))
    }

    func newVersion(_ name: String, system: String, notes: String, teach: Bool) async throws -> ModelVersion {
        var body: [String: Any] = ["system": system, "notes": notes]
        if teach { body["examples_from_feedback"] = 20 }
        let data = try await perform(request("api/models/\(name)/versions", method: "POST", body: body))
        return try Self.decoder.decode(ModelVersion.self, from: data)
    }

    func feedback(model: String, messages: [[String: String]], rating: Int) async throws {
        let body: [String: Any] = ["model": model, "messages": messages, "rating": rating]
        _ = try await perform(request("api/feedback", method: "POST", body: body))
    }

    /// Streams the reply text piece by piece as the model writes it.
    func streamChat(model: String, messages: [[String: String]], temperature: Double?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
                    if let temperature { body["temperature"] = temperature }
                    let bytes = try await openStream(request("v1/chat/completions", method: "POST", body: body))
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw APIError.server(err["message"] as? String ?? "The model stopped with an error.")
                        }
                        if let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Downloads a base model onto the server, reporting progress.
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await openStream(request("api/base-models/pull", method: "POST", body: ["model": model]))
                    for try await line in bytes.lines where !line.isEmpty {
                        let p = try Self.decoder.decode(PullProgress.self, from: Data(line.utf8))
                        if let error = p.error { throw APIError.server(error) }
                        continuation.yield(p)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await perform(request(path))
        return try Self.decoder.decode(T.self, from: data)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 600
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        try Self.check(response, data)
        return data
    }

    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65_536 { break }
            }
            try Self.check(response, data)
        }
        return bytes
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        if http.statusCode == 401 { throw APIError.unauthorized }
        throw APIError.server(message(from: data) ?? "Server error \(http.statusCode)")
    }

    private static func message(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = obj["detail"] as? String { return detail }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return nil
    }
}

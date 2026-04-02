import Foundation

final class OllamaClient: InferenceProvider, @unchecked Sendable {
    let host: String
    private let session: URLSession
    private let keepAlive = "4h"

    init(host: String = "http://localhost:11434") {
        self.host = host
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - Chat (non-streaming)

    func chat(
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]? = nil,
        temperature: Double = 0.7,
        numCtx: Int = 8192,
        timeout: TimeInterval? = nil
    ) async throws -> ChatResponse {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": ["temperature": temperature, "num_ctx": numCtx],
            "keep_alive": keepAlive,
            "think": false,
        ]
        if let tools { payload["tools"] = tools }

        let data = try await post("/api/chat", payload: payload, timeout: timeout)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let message = json["message"] as? [String: Any] ?? [:]

        // Some models put output in "thinking" key when think mode leaks through
        var content = message["content"] as? String ?? ""
        if content.isEmpty, let thinking = message["thinking"] as? String {
            content = thinking
        }

        return ChatResponse(
            content: content,
            toolCalls: message["tool_calls"] as? [[String: Any]]
        )
    }

    // MARK: - Chat (streaming)

    func chatStream(
        model: String,
        messages: [[String: Any]],
        temperature: Double = 0.7,
        numCtx: Int = 8192
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let payload: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        "options": ["temperature": temperature, "num_ctx": numCtx],
                        "keep_alive": keepAlive,
                        "think": false,
                    ]

                    let request = try makeRequest("/api/chat", payload: payload)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw OllamaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let message = json["message"] as? [String: Any],
                              let content = message["content"] as? String,
                              !content.isEmpty
                        else { continue }

                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Embed

    func embed(model: String, text: [String]) async throws -> [[Float]] {
        let payload: [String: Any] = ["model": model, "input": text]
        let data = try await post("/api/embed", payload: payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["embeddings"] as? [[Float]] ?? []
    }

    // MARK: - List Models

    func listModels() async throws -> [ModelInfo] {
        let url = URL(string: "\(host)/api/tags")!
        let (data, _) = try await session.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = json["models"] as? [[String: Any]] ?? []
        return models.map {
            ModelInfo(name: $0["name"] as? String ?? "", size: $0["size"] as? Int64)
        }
    }

    // MARK: - Pull Model

    /// Pull a model from Ollama registry. Returns progress updates (0.0 to 1.0).
    func pullModel(_ model: String) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let payload: [String: Any] = ["name": model, "stream": true]
                    let request = try makeRequest("/api/pull", payload: payload)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw OllamaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let total = json["total"] as? Double, total > 0,
                           let completed = json["completed"] as? Double {
                            continuation.yield(completed / total)
                        }

                        if let status = json["status"] as? String, status == "success" {
                            continuation.yield(1.0)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Check if a specific model is installed.
    func hasModel(_ name: String) async -> Bool {
        do {
            let models = try await listModels()
            return models.contains { $0.name == name || $0.name.hasPrefix(name + ":") }
        } catch {
            return false
        }
    }

    // MARK: - Warm Model

    func warmModel(_ model: String) async throws {
        Log.inference.info("Warming \(model)...")
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "stream": false,
            "options": ["num_ctx": 512, "num_predict": 1],
            "keep_alive": keepAlive,
        ]
        _ = try await post("/api/chat", payload: payload, timeout: 120)
        Log.inference.info("\(model) warm")
    }

    // MARK: - Connectivity

    func isReachable() async -> Bool {
        guard let url = URL(string: "\(host)/api/tags") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func makeRequest(_ path: String, payload: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: "\(host)\(path)") else {
            throw OllamaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func post(_ path: String, payload: [String: Any], timeout: TimeInterval? = nil) async throws -> Data {
        var request = try makeRequest(path, payload: payload)
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw OllamaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

enum OllamaError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Ollama URL"
        case .httpError(let code): "Ollama returned HTTP \(code)"
        }
    }
}

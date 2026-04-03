import Foundation

struct ChatResponse {
    let content: String
    let toolCalls: [[String: Any]]?

    /// Performance metrics from the inference provider.
    var tokensPerSecond: Double?
    var timeToFirstToken: TimeInterval?
    var totalTokens: Int?
}

struct ModelInfo {
    let name: String
    let size: Int64?
    var backend: String?   // "ollama" or "mlx"
    var quantization: String?
}

protocol InferenceProvider: Sendable {
    func chat(
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        temperature: Double,
        numCtx: Int,
        timeout: TimeInterval?
    ) async throws -> ChatResponse

    func chatStream(
        model: String,
        messages: [[String: Any]],
        temperature: Double,
        numCtx: Int
    ) -> AsyncThrowingStream<String, Error>

    func embed(model: String, text: [String]) async throws -> [[Float]]
    func listModels() async throws -> [ModelInfo]
    func warmModel(_ model: String) async throws
}

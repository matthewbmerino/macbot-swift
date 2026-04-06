import XCTest
@testable import Macbot

/// URLProtocol stub that records every outgoing request and returns a canned
/// JSON body. Lets us inspect what OllamaClient actually serializes without
/// needing a running Ollama instance.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var lastRequestURL: URL?
    nonisolated(unsafe) static var responseBody: Data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestURL = request.url
        // URLRequest body is stripped when going through URLProtocol — read
        // from httpBodyStream instead.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            Self.lastRequestBody = data
        } else {
            Self.lastRequestBody = request.httpBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OllamaClientTests: XCTestCase {

    private func makeClient() -> OllamaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.lastRequestBody = nil
        StubURLProtocol.lastRequestURL = nil
        return OllamaClient(host: "http://stub", session: session)
    }

    private func payload() throws -> [String: Any] {
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody, "no request body captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testChatRequestIncludesKeepAlive() async throws {
        StubURLProtocol.responseBody = #"{"message":{"content":"hi","tool_calls":null}}"#.data(using: .utf8)!
        let client = makeClient()
        _ = try await client.chat(
            model: "qwen3.5:9b",
            messages: [["role": "user", "content": "hello"]],
            tools: nil,
            temperature: 0.7,
            numCtx: 8192,
            timeout: nil
        )
        let body = try payload()
        XCTAssertEqual(body["keep_alive"] as? String, "5m",
                       "chat() must serialize keep_alive=5m so models actually unload")
        XCTAssertEqual(body["model"] as? String, "qwen3.5:9b")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, 0.7)
        XCTAssertEqual(options["num_ctx"] as? Int, 8192)
        XCTAssertEqual(StubURLProtocol.lastRequestURL?.path, "/api/chat")
    }

    func testWarmModelRequestIncludesKeepAlive() async throws {
        StubURLProtocol.responseBody = #"{"message":{"content":""}}"#.data(using: .utf8)!
        let client = makeClient()
        try await client.warmModel("qwen3.5:9b")
        let body = try payload()
        XCTAssertEqual(body["keep_alive"] as? String, "5m")
        XCTAssertEqual(body["model"] as? String, "qwen3.5:9b")
    }

    func testChatRequestSerializesToolsWhenProvided() async throws {
        StubURLProtocol.responseBody = #"{"message":{"content":"ok","tool_calls":null}}"#.data(using: .utf8)!
        let client = makeClient()
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "foo"]]]
        _ = try await client.chat(
            model: "m",
            messages: [["role": "user", "content": "hi"]],
            tools: tools,
            temperature: 0.5,
            numCtx: 4096,
            timeout: nil
        )
        let body = try payload()
        XCTAssertNotNil(body["tools"])
    }

    func testChatRequestThinkFlagIsFalse() async throws {
        StubURLProtocol.responseBody = #"{"message":{"content":"ok"}}"#.data(using: .utf8)!
        let client = makeClient()
        _ = try await client.chat(
            model: "m",
            messages: [["role": "user", "content": "hi"]],
            tools: nil,
            temperature: 0.7,
            numCtx: 8192,
            timeout: nil
        )
        let body = try payload()
        XCTAssertEqual(body["think"] as? Bool, false,
                       "think flag should be off — leaked thinking tags pollute responses")
    }

    func testEmbedRequestShape() async throws {
        // NOTE: only verifies request serialization, not response decoding.
        // OllamaClient.embed currently does `as? [[Float]]` against the
        // JSONSerialization output, but JSONSerialization produces Double
        // values — the Swift bridge will not coerce `[[Double]]` to
        // `[[Float]]`, so the result silently becomes []. Tracked in TODO.md.
        StubURLProtocol.responseBody = #"{"embeddings":[[0.1,0.2,0.3]]}"#.data(using: .utf8)!
        let client = makeClient()
        _ = try? await client.embed(model: "qwen3-embedding:0.6b", text: ["hello"])
        let body = try payload()
        XCTAssertEqual(body["model"] as? String, "qwen3-embedding:0.6b")
        XCTAssertEqual(body["input"] as? [String], ["hello"])
        XCTAssertEqual(StubURLProtocol.lastRequestURL?.path, "/api/embed")
    }
}

import XCTest
@testable import uTerm

final class AnthropicClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testStreamHitsCorrectEndpointAndHeaders() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = AnthropicClient(session: makeStubbedSession())
        let config = LLMRequestConfig(
            model: "claude-opus-4-7",
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-xxx")
        let stream = client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                    system: "be helpful", config: config)
        for try await _ in stream {}

        let req = StubURLProtocol.capturedRequest()!
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-xxx")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
    }

    func testBodyContainsModelSystemAndMessages() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = AnthropicClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "claude-opus-4-7",
                                        baseURL: URL(string: "https://api.anthropic.com")!,
                                        apiKey: "sk-ant")
        let stream = client.stream(
            messages: [ChatMessage(role: .user, text: "hi")],
            system: "S", config: config)
        for try await _ in stream {}

        let body = try XCTUnwrap(StubURLProtocol.capturedRequest()?.httpBody
            ?? bodyFromStream(StubURLProtocol.capturedRequest()))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "claude-opus-4-7")
        XCTAssertEqual(obj["system"] as? String, "S")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        let msgs = obj["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        // 消息内容一律是内容块数组（AgentKit 的 Anthropic 序列化）。
        let content = try XCTUnwrap(msgs[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "hi")
    }

    func testStreamingDeltasParsed() async throws {
        let sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}

        data: {"type":"message_stop"}

        """
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil,
                                        headerFields: ["content-type": "text/event-stream"])!
            return (resp, sse.data(using: .utf8)!)
        }
        let client = AnthropicClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "x", baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k")
        var out = ""
        for try await event in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {
            if case let .text(delta) = event { out += delta }
        }
        XCTAssertEqual(out, "Hi there")
    }

    // MARK: - 流怎么收的尾：话说一半就停必须报出来，不能装成正常结束

    private func streamError(for sse: String) async -> LLMClientError? {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["content-type": "text/event-stream"])!
            return (resp, sse.data(using: .utf8)!)
        }
        let client = AnthropicClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "x", baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k")
        do {
            for try await _ in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {}
            return nil
        } catch {
            return error as? LLMClientError
        }
    }

    /// 连接在 `message_stop` 之前断开（中转网关掐流最常见的样子）：不能当成说完了。
    func testEOFBeforeMessageStopIsIncomplete() async {
        let error = await streamError(for: """
        data: {"type":"message_start","message":{}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"而你的 ZFS 池 nvme（"}}

        """)
        XCTAssertEqual(error, .incompleteStream)
    }

    func testMidStreamErrorEventIsSurfaced() async {
        let error = await streamError(for: """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """)
        XCTAssertEqual(error, .streamError("overloaded_error：Overloaded"))
    }

    func testMaxTokensStopReasonIsSurfaced() async {
        let error = await streamError(for: """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}

        data: {"type":"message_stop"}

        """)
        XCTAssertEqual(error, .outputLimitReached)
    }

    /// 个别中转不转发 `message_stop`：有 `stop_reason` 也算正常收尾。
    func testStopReasonAloneCountsAsComplete() async {
        let error = await streamError(for: """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        """)
        XCTAssertNil(error)
    }

    func testHttpErrorMapped() async {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, "{\"error\":\"unauthorized\"}".data(using: .utf8)!)
        }
        let client = AnthropicClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "x", baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k")
        do {
            for try await _ in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {}
            XCTFail("应抛错")
        } catch let e as LLMClientError {
            guard case .httpError(let status, _) = e else { return XCTFail("应为 httpError") }
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("应为 LLMClientError，得到 \(error)")
        }
    }

    private func bodyFromStream(_ req: URLRequest?) -> Data? {
        guard let stream = req?.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 1024)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

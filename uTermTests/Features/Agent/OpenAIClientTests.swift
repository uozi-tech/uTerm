import AgentKit
import XCTest
@testable import uTerm

final class OpenAIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testEndpointAndAuthorizationHeader() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!,
                                        apiKey: "sk-test")
        for try await _ in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                          system: "", config: config) {}
        let req = StubURLProtocol.capturedRequest()!
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testCustomBaseURLForCompatibleEndpoint() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "deepseek-chat",
                                        baseURL: URL(string: "https://api.deepseek.com")!,
                                        apiKey: "sk-x")
        for try await _ in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                          system: "", config: config) {}
        XCTAssertEqual(StubURLProtocol.capturedRequest()?.url?.absoluteString,
                       "https://api.deepseek.com/v1/chat/completions")
    }

    func testSystemBecomesFirstMessage() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!,
                                        apiKey: "k")
        for try await _ in client.stream(
            messages: [ChatMessage(role: .user, text: "hello")],
            system: "you are pong-bot", config: config) {}
        let captured = StubURLProtocol.capturedRequest()!
        let body = try XCTUnwrap(captured.httpBody ?? bodyFromStream(captured))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "gpt-5")
        XCTAssertEqual(obj["stream"] as? Bool, true)
        let msgs = obj["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[0]["content"] as? String, "you are pong-bot")
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
        XCTAssertEqual(msgs[1]["content"] as? String, "hello")
    }

    func testSystemOmittedWhenEmpty() async throws {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!, apiKey: "k")
        for try await _ in client.stream(messages: [ChatMessage(role: .user, text: "x")],
                                          system: "", config: config) {}
        let captured = StubURLProtocol.capturedRequest()!
        let body = try XCTUnwrap(captured.httpBody ?? bodyFromStream(captured))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let msgs = obj["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
    }

    func testStreamingDeltasParsed() async throws {
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: [DONE]

        """
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil,
                                        headerFields: ["content-type": "text/event-stream"])!
            return (resp, sse.data(using: .utf8)!)
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!, apiKey: "k")
        var out = ""
        for try await event in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {
            if case let .text(delta) = event { out += delta }
        }
        XCTAssertEqual(out, "Hi there")
    }

    // MARK: - FIX #29: EOF 兜底 flush 工具调用

    /// 流以 finish_reason "stop" 收尾且不发 [DONE]：累积的工具调用必须靠 client
    /// 在字节流 EOF 后的兜底 flush 产出，否则被静默丢弃。
    func testToolCallFlushedOnEofWhenFinishReasonStopNoDone() async throws {
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_eof","function":{"name":"run_command","arguments":"{\\"command\\":\\"pwd\\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil,
                                        headerFields: ["content-type": "text/event-stream"])!
            return (resp, sse.data(using: .utf8)!)
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!, apiKey: "k")
        var toolCalls: [LLMToolCall] = []
        for try await event in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {
            if case let .toolCall(c) = event { toolCalls.append(c) }
        }
        XCTAssertEqual(toolCalls, [LLMToolCall(id: "call_eof", name: "run_command",
                                               argumentsJSON: #"{"command":"pwd"}"#)])
    }

    /// [DONE] 收尾的流：循环内已 flush，EOF 兜底 flush 不得重复产出同一工具调用。
    func testToolCallNotDoubleEmittedWhenDoneTerminated() async throws {
        let sse = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_once","function":{"name":"run_command","arguments":"{}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200,
                                        httpVersion: nil,
                                        headerFields: ["content-type": "text/event-stream"])!
            return (resp, sse.data(using: .utf8)!)
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!, apiKey: "k")
        var toolCalls: [LLMToolCall] = []
        for try await event in client.stream(messages: [ChatMessage(role: .user, text: "hi")],
                                              system: "", config: config) {
            if case let .toolCall(c) = event { toolCalls.append(c) }
        }
        XCTAssertEqual(toolCalls, [LLMToolCall(id: "call_once", name: "run_command",
                                               argumentsJSON: "{}")])
    }

    func testHttpErrorMapped() async {
        StubURLProtocol.install { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!
            return (resp, "unauthorized".data(using: .utf8)!)
        }
        let client = OpenAIClient(session: makeStubbedSession())
        let config = LLMRequestConfig(model: "gpt-5",
                                        baseURL: URL(string: "https://api.openai.com")!, apiKey: "bad")
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

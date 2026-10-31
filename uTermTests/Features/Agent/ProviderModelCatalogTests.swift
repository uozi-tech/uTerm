import XCTest
@testable import uTerm

final class ProviderModelCatalogTests: XCTestCase {
    private let root = URL(string: "https://api.example.com")!

    // MARK: - 请求

    func testOpenAIRequestUsesV1ModelsWithBearer() {
        let request = ProviderModelCatalog.request(kind: .openai, baseURL: root, apiKey: " sk-1 ")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testAnthropicRequestUsesAPIKeyHeaderAndOnePage() {
        let request = ProviderModelCatalog.request(kind: .anthropic, baseURL: root, apiKey: "ak")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models?limit=1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ak")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// 本机 Ollama 等无 key 端点：不发空的 Authorization。
    func testEmptyKeySendsNoAuthHeader() {
        let request = ProviderModelCatalog.request(kind: .openai,
                                                   baseURL: URL(string: "http://localhost:11434")!,
                                                   apiKey: "  ")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - 解码

    func testDecodeKeepsServerOrderDropsBlanksAndDuplicates() throws {
        let json = #"{"data":[{"id":"claude-opus","type":"model"},{"id":" "},{"id":"claude-haiku"},{"id":"claude-opus"}],"has_more":false}"#
        XCTAssertEqual(try ProviderModelCatalog.decodeModelIDs(Data(json.utf8)), ["claude-opus", "claude-haiku"])
    }

    func testDecodeRejectsUnexpectedShape() {
        XCTAssertThrowsError(try ProviderModelCatalog.decodeModelIDs(Data(#"{"models":[]}"#.utf8))) {
            XCTAssertEqual($0 as? LLMClientError, .invalidResponse)
        }
    }

    // MARK: - 文案

    func testErrorMessages() {
        XCTAssertEqual(ProviderModelCatalog.message(for: LLMClientError.httpError(status: 401, body: "")),
                       "认证失败，请检查 API Key")
        XCTAssertEqual(ProviderModelCatalog.message(for: LLMClientError.httpError(status: 404, body: "x")),
                       "该端点没有 /v1/models 模型列表接口，检查 Base URL")
        XCTAssertEqual(ProviderModelCatalog.message(for: LLMClientError.httpError(status: 500, body: "boom")),
                       "HTTP 500：boom")
    }
}

@MainActor
final class ProviderModelListTests: XCTestCase {
    private let request = ProviderModelList.Request(kind: .openai, baseURL: "https://api.example.com", apiKey: "k")

    func testLoadSucceeds() async {
        let list = ProviderModelList { _, _, _ in ["a", "b"] }
        list.load(request)
        XCTAssertEqual(list.phase, .loading)
        await list.waitUntilSettled()
        XCTAssertEqual(list.phase, .loaded(["a", "b"]))
    }

    func testEmptyBaseURLFallsBackToKindDefault() async {
        let seen = Recorder()
        let list = ProviderModelList { _, url, _ in await seen.append(url.absoluteString); return [] }
        list.load(.init(kind: .anthropic, baseURL: "", apiKey: "k"))
        await list.waitUntilSettled()
        let urls = await seen.values
        XCTAssertEqual(urls, [ProviderPreset.anthropicBaseURL])
        XCTAssertEqual(list.phase, .loaded([]))
    }

    /// 不安全 / 非法的 Base URL 不发请求（输入框自己会报错）。
    func testInvalidBaseURLStaysIdle() async {
        let seen = Recorder()
        let list = ProviderModelList { _, url, _ in await seen.append(url.absoluteString); return ["x"] }
        list.load(.init(kind: .openai, baseURL: "http://192.168.1.20:11434", apiKey: "k"))
        await list.waitUntilSettled()
        XCTAssertEqual(list.phase, .idle)
        let urls = await seen.values
        XCTAssertTrue(urls.isEmpty)
    }

    func testFailureCarriesReasonAndRetryRepeatsRequest() async {
        let calls = Recorder()
        let list = ProviderModelList { _, _, _ in
            await calls.append("call")
            if await calls.values.count == 1 { throw LLMClientError.httpError(status: 401, body: "") }
            return ["m"]
        }
        list.load(request)
        await list.waitUntilSettled()
        XCTAssertEqual(list.phase, .failed("认证失败，请检查 API Key"))
        list.retry()
        await list.waitUntilSettled()
        XCTAssertEqual(list.phase, .loaded(["m"]))
    }

    /// 端点改了：只有最新一次请求能落地。
    func testNewerLoadSupersedesInFlightOne() async {
        let list = ProviderModelList { _, url, _ in
            if url.host() == "old.example.com" {
                try await Task.sleep(for: .milliseconds(200))
                return ["stale"]
            }
            return ["fresh"]
        }
        list.load(.init(kind: .openai, baseURL: "https://old.example.com", apiKey: ""))
        list.load(.init(kind: .openai, baseURL: "https://new.example.com", apiKey: ""))
        await list.waitUntilSettled()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(list.phase, .loaded(["fresh"]))
    }

    func testDebouncedLoadsCollapseIntoOneFetch() async {
        let seen = Recorder()
        let list = ProviderModelList { _, _, key in await seen.append(key); return ["m"] }
        for key in ["s", "sk", "sk-1"] {
            list.load(.init(kind: .openai, baseURL: "https://api.example.com", apiKey: key),
                      debounce: .milliseconds(50))
        }
        await list.waitUntilSettled()
        let keys = await seen.values
        XCTAssertEqual(keys, ["sk-1"])
    }

    // MARK: - 选项

    func testChoicesKeepSavedModelMissingFromList() async {
        let choices = ProviderModelChoices(phase: .loaded(["a", "b"]), saved: "gone")
        XCTAssertEqual(choices.models, ["gone", "a", "b"])
        XCTAssertTrue(choices.savedIsMissing)
    }

    func testChoicesWithSavedModelInList() async {
        let choices = ProviderModelChoices(phase: .loaded(["a", "b"]), saved: "b")
        XCTAssertEqual(choices.models, ["a", "b"])
        XCTAssertFalse(choices.savedIsMissing)
    }

    /// 列表没到（或失败）时已存模型仍可见，但不标「不在列表」——没有证据说它没了。
    func testChoicesBeforeListArrives() async {
        for phase: ProviderModelList.Phase in [.idle, .loading, .failed("x")] {
            let choices = ProviderModelChoices(phase: phase, saved: "a")
            XCTAssertEqual(choices.models, ["a"])
            XCTAssertFalse(choices.savedIsMissing)
        }
    }

    func testChoicesFilterIsCaseInsensitive() async {
        let choices = ProviderModelChoices(phase: .loaded(["gpt-5", "GPT-4o", "claude"]), saved: "")
        XCTAssertEqual(choices.filtered(by: " gpt "), ["gpt-5", "GPT-4o"])
    }
}

private actor Recorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

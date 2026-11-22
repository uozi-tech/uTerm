import AgentKit
import Foundation

/// 向 provider 拉可用模型列表 —— 设置里模型下拉的唯一来源（不预置、不手填）。
///
/// 两种 kind 都是 `GET {baseURL}/v1/models`（与 client 的 `v1/chat/completions` /
/// `v1/messages` 同根）：OpenAI 兼容带 `Authorization: Bearer`，Anthropic 带
/// `x-api-key` + `anthropic-version` 并 `limit=1000` 一页取完。两边响应都是
/// `{ "data": [ { "id": … } ] }`，一个解码器通吃；按服务端顺序去重、去空白。
/// 请求与解码在 `AgentKit.LLMWireTransport`（uTable 共用），这里只管本应用的地址约定与错误类型。
nonisolated enum ProviderModelCatalog {
    static func fetchModels(kind: ProviderKind,
                            baseURL: URL,
                            apiKey: String,
                            session: URLSession = .shared) async throws -> [String] {
        do {
            return try await LLMWireTransport.fetchModelIDs(
                url: modelsURL(kind: kind, baseURL: baseURL), apiKey: apiKey,
                wireProtocol: kind.wireProtocol, session: session)
        } catch let LLMWireError.http(status, body, _) {
            throw LLMClientError.httpError(status: status, body: String(body.prefix(300)))
        } catch {
            throw LLMClientError.map(error)
        }
    }

    static func modelsURL(kind: ProviderKind, baseURL: URL) -> URL {
        var url = baseURL.appendingPathComponent("v1/models")
        if kind == .anthropic {
            url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        }
        return url
    }

    static func request(kind: ProviderKind, baseURL: URL, apiKey: String) -> URLRequest {
        LLMWireTransport.modelListRequest(url: modelsURL(kind: kind, baseURL: baseURL), apiKey: apiKey,
                                          wireProtocol: kind.wireProtocol)
    }

    static func decodeModelIDs(_ data: Data) throws -> [String] {
        do {
            return try LLMWireTransport.decodeModelIDs(data)
        } catch {
            throw LLMClientError.map(error)
        }
    }

    /// 设置页状态行文案。
    static func message(for error: Error) -> String {
        switch error as? LLMClientError {
        case .httpError(401, _), .httpError(403, _):
            return String(localized: "认证失败，检查 API Key")
        case .httpError(404, _):
            return String(localized: "该端点没有 /v1/models 模型列表接口，检查 Base URL")
        case .httpError(429, _):
            return String(localized: "请求过于频繁，稍后再试")
        case .httpError(let status, let body):
            return body.isEmpty ? "HTTP \(status)" : String(localized: "HTTP \(String(status))：\(String(body.prefix(120)))")
        case .invalidResponse:
            return String(localized: "模型服务返回了无法解析的模型列表")
        default:
            return String(localized: "获取失败：\(FriendlyError.describe(error))")
        }
    }
}

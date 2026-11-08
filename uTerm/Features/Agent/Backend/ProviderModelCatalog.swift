import Foundation

/// 向 provider 拉可用模型列表 —— 设置里模型下拉的唯一来源（不预置、不手填）。
///
/// 两种 kind 都是 `GET {baseURL}/v1/models`（与 client 的 `v1/chat/completions` /
/// `v1/messages` 同根）：OpenAI 兼容带 `Authorization: Bearer`，Anthropic 带
/// `x-api-key` + `anthropic-version` 并 `limit=1000` 一页取完。两边响应都是
/// `{ "data": [ { "id": … } ] }`，一个解码器通吃；按服务端顺序去重、去空白。
nonisolated enum ProviderModelCatalog {
    static func fetchModels(kind: ProviderKind,
                            baseURL: URL,
                            apiKey: String,
                            session: URLSession = .shared) async throws -> [String] {
        let (data, response) = try await session.data(for: request(kind: kind, baseURL: baseURL, apiKey: apiKey))
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.httpError(status: http.statusCode, body: String(body.prefix(300)))
        }
        return try decodeModelIDs(data)
    }

    static func request(kind: ProviderKind, baseURL: URL, apiKey: String) -> URLRequest {
        var url = baseURL.appendingPathComponent("v1/models")
        if kind == .anthropic {
            url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openai:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func decodeModelIDs(_ data: Data) throws -> [String] {
        struct ModelList: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw LLMClientError.invalidResponse
        }
        var seen = Set<String>()
        return list.data.compactMap { entry in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
    }

    /// 设置页状态行文案。
    static func message(for error: Error) -> String {
        switch error as? LLMClientError {
        case .httpError(401, _), .httpError(403, _):
            return "认证失败，检查 API Key"
        case .httpError(404, _):
            return "该端点没有 /v1/models 模型列表接口，检查 Base URL"
        case .httpError(429, _):
            return "请求过于频繁，稍后再试"
        case .httpError(let status, let body):
            return body.isEmpty ? "HTTP \(status)" : "HTTP \(status)：\(body.prefix(120))"
        case .invalidResponse:
            return "模型服务返回了无法解析的模型列表"
        default:
            return "获取失败：\(FriendlyError.describe(error))"
        }
    }
}

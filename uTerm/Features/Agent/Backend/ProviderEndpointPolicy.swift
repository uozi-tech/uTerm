import AgentKit
import Foundation

/// AI Provider 端点的统一安全策略。
///
/// API key、终端上下文和命令输出都会发往该地址，因此公网/局域网明文 HTTP 都不是
/// 可接受的降级。仅保留 loopback HTTP 给本机 Ollama 等开发服务；其它端点必须 HTTPS。
///
/// 校验规则本身（scheme / loopback / credentials / query 白名单）现由
/// `AgentKit.AgentEndpointPolicy` 统一实现（与 uTable 的 `LLMEndpointPolicy`
/// 同一份算法）；这里只保留 uTerm 特有的部分：kind 相关的默认 baseURL 代入，
/// 以及面向 Settings UI 的中文错误文案。
nonisolated enum ProviderEndpointPolicy {
    enum ValidationError: Error, Equatable {
        case invalidURL
        case unsupportedScheme
        case embeddedCredentials
        case queryOrFragment
        case insecureHTTP

        init(_ error: AgentEndpointPolicy.ValidationError) {
            switch error {
            case .invalidURL: self = .invalidURL
            case .unsupportedScheme: self = .unsupportedScheme
            case .embeddedCredentials: self = .embeddedCredentials
            case .queryOrFragment: self = .queryOrFragment
            case .insecureHTTP: self = .insecureHTTP
            }
        }

        var message: String {
            switch self {
            case .invalidURL:
                return String(localized: "填写包含主机名的有效地址")
            case .unsupportedScheme:
                return String(localized: "仅支持 HTTPS；本机服务可使用 HTTP")
            case .embeddedCredentials:
                return String(localized: "Base URL 不能包含用户名或密码")
            case .queryOrFragment:
                return String(localized: "Base URL 不能包含查询参数或片段")
            case .insecureHTTP:
                return String(localized: "远程模型服务必须使用 HTTPS；只有 localhost、127.0.0.0/8、::1 可以用 HTTP")
            }
        }
    }

    static func resolve(configuredBaseURL: String,
                        kind: ProviderKind) -> Result<URL, ValidationError> {
        let trimmed = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? ProviderPreset.defaultBaseURL(for: kind) : trimmed
        return AgentEndpointPolicy.validatedBaseURL(raw).mapError(ValidationError.init)
    }

    static func validationMessage(configuredBaseURL: String,
                                  kind: ProviderKind) -> String? {
        switch resolve(configuredBaseURL: configuredBaseURL, kind: kind) {
        case .success:
            return nil
        case .failure(let error):
            return error.message
        }
    }
}

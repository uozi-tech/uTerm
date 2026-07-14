import Foundation

/// AI Provider 端点的统一安全策略。
///
/// API key、终端上下文和命令输出都会发往该地址，因此公网/局域网明文 HTTP 都不是
/// 可接受的降级。仅保留 loopback HTTP 给本机 Ollama 等开发服务；其它端点必须 HTTPS。
nonisolated enum ProviderEndpointPolicy {
    enum ValidationError: Error, Equatable {
        case invalidURL
        case unsupportedScheme
        case embeddedCredentials
        case queryOrFragment
        case insecureHTTP

        var message: String {
            switch self {
            case .invalidURL:
                return "请填写包含主机名的合法地址"
            case .unsupportedScheme:
                return "仅支持 HTTPS；本机服务可使用 HTTP"
            case .embeddedCredentials:
                return "Base URL 不能包含用户名或密码"
            case .queryOrFragment:
                return "Base URL 不能包含查询参数或片段"
            case .insecureHTTP:
                return "远程 Provider 必须使用 HTTPS；HTTP 仅允许 localhost/127.0.0.0/8/::1"
            }
        }
    }

    static func resolve(configuredBaseURL: String,
                        kind: ProviderKind) -> Result<URL, ValidationError> {
        let trimmed = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? ProviderPreset.defaultBaseURL(for: kind) : trimmed
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return .failure(.invalidURL)
        }
        guard url.user == nil, url.password == nil else {
            return .failure(.embeddedCredentials)
        }
        guard url.query == nil, url.fragment == nil else {
            return .failure(.queryOrFragment)
        }

        switch url.scheme?.lowercased() {
        case "https":
            return .success(url)
        case "http":
            return isLoopback(host) ? .success(url) : .failure(.insecureHTTP)
        default:
            return .failure(.unsupportedScheme)
        }
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

    private static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]), first == 127,
              octets.dropFirst().allSatisfy({ UInt8($0) != nil }) else {
            return false
        }
        return true
    }
}

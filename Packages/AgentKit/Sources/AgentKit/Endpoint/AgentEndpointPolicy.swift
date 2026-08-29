import Foundation

/// Shared security policy for LLM provider endpoints, factored out of two
/// independent (and behaviorally identical) implementations: uTable's
/// `LLMEndpointPolicy` and uTerm's `ProviderEndpointPolicy`.
///
/// API keys, prompt context, and tool output/command output all flow to
/// whatever this resolves to, so a malformed custom URL must never silently
/// fall back to a different host, and plaintext HTTP must never be used
/// against a remote machine. Loopback HTTP is the one carve-out, for local
/// dev servers (Ollama, LM Studio, ...).
///
/// This type owns only the validation *rule* and URL construction. Each app
/// keeps its own error type / user-facing copy (uTerm's has Chinese messages
/// tied to its settings UI; uTable's throws through its own `LLMProviderError`)
/// by mapping from `ValidationError`.
public enum AgentEndpointPolicy {
    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidURL
        case unsupportedScheme
        case embeddedCredentials
        case queryOrFragment
        case insecureHTTP

        public var description: String {
            switch self {
            case .invalidURL: return "invalid or empty base URL"
            case .unsupportedScheme: return "base URL must use HTTPS or loopback HTTP"
            case .embeddedCredentials: return "base URL must not contain a username or password"
            case .queryOrFragment: return "base URL must not contain a query or fragment"
            case .insecureHTTP: return "remote endpoints must use HTTPS; HTTP is allowed only for loopback hosts"
            }
        }
    }

    /// Validates a base URL string against the shared policy and returns it
    /// as a `URL`. Does not append any path.
    public static func validatedBaseURL(_ raw: String) -> Result<URL, ValidationError> {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidURL) }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else {
            return .failure(.invalidURL)
        }

        guard components.user == nil, components.password == nil else {
            return .failure(.embeddedCredentials)
        }
        guard components.query == nil, components.fragment == nil else {
            return .failure(.queryOrFragment)
        }

        switch scheme {
        case "https":
            break
        case "http" where isLoopback(host):
            break
        case "http":
            return .failure(.insecureHTTP)
        default:
            return .failure(.unsupportedScheme)
        }

        guard let url = components.url else { return .failure(.invalidURL) }
        return .success(url)
    }

    /// Validates `baseURL`, then appends `path` and `queryItems` to it,
    /// returning the full endpoint URL. Throws `ValidationError`.
    public static func endpoint(
        baseURL: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let base = try validatedBaseURL(baseURL).get()
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ValidationError.invalidURL
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + (path.hasPrefix("/") ? path : "/" + path)
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else { throw ValidationError.invalidURL }
        return url
    }

    /// A host that never leaves the local machine: `localhost` (and any
    /// `*.localhost` subdomain), `::1`, or a `127.0.0.0/8` literal.
    public static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host == "localhost" || host == "localhost." || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]), first == 127,
              octets.dropFirst().allSatisfy({ UInt8($0) != nil })
        else {
            return false
        }
        return true
    }
}

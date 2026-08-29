import XCTest
@testable import AgentKit

final class AgentEndpointPolicyTests: XCTestCase {

    private func resolved(_ raw: String) throws -> URL {
        try AgentEndpointPolicy.validatedBaseURL(raw).get()
    }

    private func assertFailure(
        _ raw: String,
        _ expected: AgentEndpointPolicy.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch AgentEndpointPolicy.validatedBaseURL(raw) {
        case .success(let url):
            XCTFail("expected failure, got \(url)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    func testHTTPSRemoteEndpointIsAllowed() throws {
        XCTAssertEqual(try resolved("https://api.example.com/proxy").absoluteString, "https://api.example.com/proxy")
    }

    func testHTTPLoopbackEndpointsAreAllowed() throws {
        XCTAssertNoThrow(try resolved("http://localhost:11434"))
        XCTAssertNoThrow(try resolved("http://model.localhost:11434"))
        XCTAssertNoThrow(try resolved("http://127.42.0.1:11434"))
        XCTAssertNoThrow(try resolved("http://[::1]:11434"))
        XCTAssertNoThrow(try resolved("http://127.0.0.1:11434/v1"))
    }

    func testHTTPRemoteAndLANEndpointsAreRejected() {
        assertFailure("http://api.example.com", .insecureHTTP)
        assertFailure("http://192.168.1.20:11434", .insecureHTTP)
        assertFailure("http://localhost.example.com", .insecureHTTP)
        assertFailure("http://127.0.0.1.example.com/v1", .insecureHTTP)
    }

    func testCredentialsQueryAndFragmentAreRejected() {
        assertFailure("https://user:secret@example.com", .embeddedCredentials)
        assertFailure("https://example.com?token=secret", .queryOrFragment)
        assertFailure("https://example.com/#fragment", .queryOrFragment)
    }

    func testEmptyOrMalformedURLIsRejected() {
        assertFailure("", .invalidURL)
        assertFailure("not a valid URL", .invalidURL)
    }

    func testUnsupportedSchemeIsRejected() {
        assertFailure("ftp://example.com", .unsupportedScheme)
    }

    // MARK: - endpoint(baseURL:path:queryItems:)

    func testEndpointAppendsPathToValidatedBase() throws {
        let url = try AgentEndpointPolicy.endpoint(baseURL: "https://api.anthropic.com", path: "/v1/messages")
        XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testEndpointNormalizesTrailingSlashesOnBaseAndPath() throws {
        let url = try AgentEndpointPolicy.endpoint(baseURL: "https://api.openai.com/v1/", path: "chat/completions")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testEndpointAppendsQueryItems() throws {
        let url = try AgentEndpointPolicy.endpoint(
            baseURL: "https://api.anthropic.com",
            path: "/v1/models",
            queryItems: [URLQueryItem(name: "limit", value: "1000")]
        )
        XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
    }

    func testEndpointRejectsMalformedOrInsecureBase() {
        XCTAssertThrowsError(try AgentEndpointPolicy.endpoint(baseURL: "not a valid URL", path: "/v1/messages"))
        XCTAssertThrowsError(try AgentEndpointPolicy.endpoint(baseURL: "http://api.example.com/v1", path: "/chat"))
        XCTAssertThrowsError(try AgentEndpointPolicy.endpoint(baseURL: "https://user:secret@example.com", path: "/v1"))
    }
}

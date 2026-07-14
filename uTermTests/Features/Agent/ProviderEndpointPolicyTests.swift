import XCTest
@testable import uTerm

final class ProviderEndpointPolicyTests: XCTestCase {
    func testHTTPSRemoteEndpointIsAllowed() throws {
        let url = try resolved("https://api.example.com/proxy", kind: .openai)
        XCTAssertEqual(url.absoluteString, "https://api.example.com/proxy")
    }

    func testEmptyEndpointUsesSecureProviderDefault() throws {
        let url = try resolved("", kind: .anthropic)
        XCTAssertEqual(url.absoluteString, ProviderPreset.anthropicBaseURL)
    }

    func testHTTPLoopbackEndpointsAreAllowed() throws {
        XCTAssertNoThrow(try resolved("http://localhost:11434", kind: .openai))
        XCTAssertNoThrow(try resolved("http://model.localhost:11434", kind: .openai))
        XCTAssertNoThrow(try resolved("http://127.42.0.1:11434", kind: .openai))
        XCTAssertNoThrow(try resolved("http://[::1]:11434", kind: .openai))
    }

    func testHTTPRemoteAndLANEndpointsAreRejected() {
        assertFailure("http://api.example.com", .insecureHTTP)
        assertFailure("http://192.168.1.20:11434", .insecureHTTP)
        assertFailure("http://localhost.example.com", .insecureHTTP)
    }

    func testCredentialsQueryAndFragmentAreRejected() {
        assertFailure("https://user:secret@example.com", .embeddedCredentials)
        assertFailure("https://example.com?token=secret", .queryOrFragment)
        assertFailure("https://example.com/#fragment", .queryOrFragment)
    }

    private func resolved(_ raw: String, kind: ProviderKind) throws -> URL {
        switch ProviderEndpointPolicy.resolve(configuredBaseURL: raw, kind: kind) {
        case .success(let url): return url
        case .failure(let error): throw error
        }
    }

    private func assertFailure(
        _ raw: String,
        _ expected: ProviderEndpointPolicy.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch ProviderEndpointPolicy.resolve(configuredBaseURL: raw, kind: .openai) {
        case .success(let url):
            XCTFail("expected failure, got \(url)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

import XCTest
import SwiftData
@testable import uTerm

final class HostKeyVerifierTests: XCTestCase {
    private func makeVerifier() throws -> HostKeyVerifier {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KnownHost.self, configurations: config)
        return HostKeyVerifier(modelContainer: container)
    }

    func testUnknownHost() async throws {
        let v = try makeVerifier()
        let result = await v.classify(host: "h1", port: 22,
                                      keyBlob: Data([1]), fingerprint: "SHA256:one")
        XCTAssertEqual(result, .unknown(fingerprint: "SHA256:one"))
    }

    func testTrustThenTrusted() async throws {
        let v = try makeVerifier()
        await v.trust(host: "h1", port: 22, keyBlob: Data([1]),
                      keyType: "ssh-ed25519", fingerprint: "SHA256:one")
        let result = await v.classify(host: "h1", port: 22,
                                      keyBlob: Data([1]), fingerprint: "SHA256:one")
        XCTAssertEqual(result, .trusted)
    }

    func testMismatch() async throws {
        let v = try makeVerifier()
        await v.trust(host: "h1", port: 22, keyBlob: Data([1]),
                      keyType: "ssh-ed25519", fingerprint: "SHA256:one")
        let result = await v.classify(host: "h1", port: 22,
                                      keyBlob: Data([9]), fingerprint: "SHA256:nine")
        XCTAssertEqual(result, .mismatch(newFingerprint: "SHA256:nine",
                                         oldFingerprint: "SHA256:one"))
    }

    func testTrustUpdatesExistingOnOverride() async throws {
        let v = try makeVerifier()
        await v.trust(host: "h1", port: 22, keyBlob: Data([1]),
                      keyType: "ssh-ed25519", fingerprint: "SHA256:one")
        await v.trust(host: "h1", port: 22, keyBlob: Data([9]),
                      keyType: "ssh-ed25519", fingerprint: "SHA256:nine")
        let result = await v.classify(host: "h1", port: 22,
                                      keyBlob: Data([9]), fingerprint: "SHA256:nine")
        XCTAssertEqual(result, .trusted)
        let count = await v.knownHostCount(host: "h1", port: 22)
        XCTAssertEqual(count, 1)
    }

    func testPortIsPartOfIdentity() async throws {
        let v = try makeVerifier()
        await v.trust(host: "h1", port: 22, keyBlob: Data([1]),
                      keyType: "ssh-ed25519", fingerprint: "SHA256:one")
        let result = await v.classify(host: "h1", port: 2222,
                                      keyBlob: Data([1]), fingerprint: "SHA256:one")
        XCTAssertEqual(result, .unknown(fingerprint: "SHA256:one"))
    }
}

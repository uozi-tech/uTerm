import XCTest
import SwiftData
@testable import uTerm
@testable import USSHKit

@MainActor
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

    /// 回归：CloudKit 离线合并可能留下同一 host:port 的多条记录。只要其中有
    /// 一条与当前密钥冲突，就不能因 fetch 顺序碰巧先取到匹配项而静默信任。
    func testConflictingCloudKitDuplicatesFailClosed() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KnownHost.self, configurations: config)
        let context = container.mainContext

        let matching = KnownHost()
        matching.host = "h1"
        matching.port = 22
        matching.keyBlob = Data([1])
        matching.fingerprint = "SHA256:one"
        matching.firstTrustedAt = Date(timeIntervalSince1970: 2)
        context.insert(matching)

        let conflicting = KnownHost()
        conflicting.host = "h1"
        conflicting.port = 22
        conflicting.keyBlob = Data([9])
        conflicting.fingerprint = "SHA256:nine"
        conflicting.firstTrustedAt = Date(timeIntervalSince1970: 1)
        context.insert(conflicting)
        try context.save()

        let verifier = HostKeyVerifier(modelContainer: container)
        let result = await verifier.classify(
            host: "h1", port: 22, keyBlob: Data([1]), fingerprint: "SHA256:one")

        XCTAssertEqual(result, .mismatch(newFingerprint: "SHA256:one",
                                         oldFingerprint: "SHA256:nine"))
    }

    func testTrustCollapsesCloudKitDuplicates() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KnownHost.self, configurations: config)
        let context = container.mainContext
        for (blob, fingerprint) in [(Data([1]), "SHA256:one"),
                                    (Data([9]), "SHA256:nine")] {
            let known = KnownHost()
            known.host = "h1"
            known.port = 22
            known.keyBlob = blob
            known.fingerprint = fingerprint
            context.insert(known)
        }
        try context.save()

        let verifier = HostKeyVerifier(modelContainer: container)
        await verifier.trust(host: "h1", port: 22, keyBlob: Data([7]),
                             keyType: "ssh-ed25519", fingerprint: "SHA256:seven")

        let count = await verifier.knownHostCount(host: "h1", port: 22)
        let classification = await verifier.classify(
            host: "h1", port: 22, keyBlob: Data([7]), fingerprint: "SHA256:seven")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(classification, .trusted)
    }
}

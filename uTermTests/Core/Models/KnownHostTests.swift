import XCTest
import SwiftData
@testable import uTerm

final class KnownHostTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: KnownHost.self, configurations: config)
        return ModelContext(container)
    }

    func testDefaultsAreSane() {
        let h = KnownHost()
        XCTAssertEqual(h.port, 22)
        XCTAssertEqual(h.host, "")
        XCTAssertEqual(h.keyBlob, Data())
    }

    func testInsertAndFetch() throws {
        let ctx = try makeContext()
        let h = KnownHost()
        h.host = "example.com"
        h.port = 2222
        h.keyTypeRaw = "ssh-ed25519"
        h.keyBlob = Data([1, 2, 3])
        h.fingerprint = "SHA256:abc"
        ctx.insert(h)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<KnownHost>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.host, "example.com")
        XCTAssertEqual(fetched.first?.port, 2222)
        XCTAssertEqual(fetched.first?.keyBlob, Data([1, 2, 3]))
        XCTAssertEqual(fetched.first?.fingerprint, "SHA256:abc")
    }
}

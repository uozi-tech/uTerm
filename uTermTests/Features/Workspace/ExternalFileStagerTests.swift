import XCTest
@testable import uTerm

final class ExternalFileStagerTests: XCTestCase {
    func testStagesSameNameIntoDistinctPrivateLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uTermStagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ExternalFileStager.stage(
            data: Data("one".utf8), suggestedName: "report.txt", rootDirectory: root)
        let second = try ExternalFileStager.stage(
            data: Data("two".utf8), suggestedName: "report.txt", rootDirectory: root)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "report.txt")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
        XCTAssertEqual(try permissions(at: first), 0o600)
        XCTAssertEqual(try permissions(at: first.deletingLastPathComponent()), 0o700)
    }

    func testSanitizesPathAndControlCharacters() {
        XCTAssertEqual(ExternalFileStager.sanitizedFileName("../../secret\n.txt"),
                       "secret_.txt")
        XCTAssertEqual(ExternalFileStager.sanitizedFileName(".."), "download")
        XCTAssertEqual(ExternalFileStager.sanitizedFileName(""), "download")
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

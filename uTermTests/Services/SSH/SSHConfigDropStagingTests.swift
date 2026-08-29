import XCTest
@testable import uTerm
@testable import USSHKit

final class SSHConfigDropStagingTests: XCTestCase {
    private func makeTmpRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropstaging-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLocateConfigInDirectory() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let cfg = sshDir.appendingPathComponent("config")
        try "Host a\n  HostName 1.2.3.4\n".write(to: cfg, atomically: true, encoding: .utf8)
        let located = SSHConfigDropStaging.locateConfig(in: sshDir)
        XCTAssertEqual(located?.config, cfg)
        XCTAssertEqual(located?.dir, sshDir)
    }

    func testLocateConfigForFile() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config")
        try "Host a\n".write(to: file, atomically: true, encoding: .utf8)
        let located = SSHConfigDropStaging.locateConfig(in: file)
        XCTAssertEqual(located?.config, file)
        XCTAssertEqual(located?.dir, root.appendingPathComponent("config").deletingLastPathComponent())
    }

    func testLocateConfigDirWithoutConfigReturnsNil() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(SSHConfigDropStaging.locateConfig(in: empty))
    }

    func testLocateConfigDirWithConfigDirectoryReturnsNil() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        // "config" exists but as a DIRECTORY, not a file → should be rejected.
        try FileManager.default.createDirectory(
            at: sshDir.appendingPathComponent("config", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertNil(SSHConfigDropStaging.locateConfig(in: sshDir))
    }

    func testStageCopiesFile() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("config")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let stagingRoot = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let staged = try SSHConfigDropStaging.stage(source: src, intoRoot: stagingRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "hello")
    }

    func testStageCopiesDirectoryRecursively() throws {
        let root = try makeTmpRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try "Host a\n".write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "KEYDATA".write(to: sshDir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        let stagingRoot = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let staged = try SSHConfigDropStaging.stage(source: sshDir, intoRoot: stagingRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("config").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("id_ed25519").path))
    }
}

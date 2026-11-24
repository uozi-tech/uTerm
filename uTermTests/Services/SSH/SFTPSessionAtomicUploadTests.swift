import XCTest
import SwiftData
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// 上传与编辑器保存「整份替换」远端文件：失败时原来的文件不动、不留半截，成功时换过去的文件保留原来的权限。
/// 目标的身份换不过去时（符号链接、服务器没有 posix-rename、属主不同）照旧原地写。
/// 服务端是进程内的测试服务端，背后是本机临时目录（`SFTPLocalFileSystem`），权限、符号链接都是真的。
final class SFTPSessionAtomicUploadTests: XCTestCase {

    private var fileSystem: SFTPLocalFileSystem!
    private var faults: SFTPFaultInjector!
    private var server: SSHTestServer!
    private var session: SFTPSession!

    override func setUp() async throws {
        try await super.setUp()
        fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "uterm-atomic-upload")
        try await start()
    }

    override func tearDown() async throws {
        await session?.close()
        await server?.stop()
        try? fileSystem?.removeRoot()
        session = nil
        server = nil
        fileSystem = nil
        try await super.tearDown()
    }

    private func start(extensions: [String: String] = SFTPServer.defaultExtensions) async throws {
        await session?.close()
        await server?.stop()
        faults = SFTPFaultInjector()
        var configuration = SSHTestServer.Configuration(authentication: .acceptAnyone)
        configuration.serveSFTP(fileSystem: fileSystem,
                                configuration: SFTPServer.Configuration(extensions: extensions),
                                faults: faults)
        server = try await SSHTestServer.start(configuration)
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let connected = try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"),
            jumpHostAuth: nil, hostKeyVerifier: verifier, hostKeyApprover: { _ in true })
        session = try await SFTPSession(connected: connected, pacesUploads: false)
    }

    private func local(_ name: String) -> URL { fileSystem.rootURL.appendingPathComponent(name) }

    private func put(_ name: String, _ text: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: local(name))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: local(name).path)
    }

    private func text(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: local(name)), as: UTF8.self)
    }

    private func mode(_ name: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: local(name).path)[.posixPermissions] as? Int ?? -1
    }

    /// 根目录里除了 `expected` 之外没有别的东西（没有留下临时文件）。
    private func assertOnly(_ expected: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: fileSystem.rootPath))
        XCTAssertEqual(names, expected, file: file, line: line)
    }

    /// 比一个 WRITE 大得多，第二个 WRITE 失败时一定已经写了一部分。
    private let big = Data(repeating: 0x61, count: 2 * 1_048_576)

    func testOverwriteReplacesTheContentAndKeepsThePermissions() async throws {
        try put("app.conf", "old", mode: 0o640)

        try await session.upload(data: Data("new".utf8), toRemotePath: "/app.conf", onProgress: nil)

        XCTAssertEqual(try text("app.conf"), "new")
        XCTAssertEqual(try mode("app.conf"), 0o640, "换过去的文件保留原来的权限")
        try assertOnly(["app.conf"])
        XCTAssertGreaterThan(faults.requestCount(of: .extended(SFTPExtensionName.posixRename)), 0,
                             "走的是临时文件 + posix-rename")
    }

    func testFailedOverwriteLeavesTheOriginalUntouched() async throws {
        try put("app.conf", "precious")
        faults.fail(.write, occurrence: 2, with: .failure, message: "disk full")

        do {
            try await session.upload(data: big, toRemotePath: "/app.conf", onProgress: nil)
            XCTFail("写到一半失败应当报错")
        } catch {}

        XCTAssertEqual(try text("app.conf"), "precious", "目标没被截断")
        try assertOnly(["app.conf"])
    }

    func testFailedNewUploadLeavesNothingBehind() async throws {
        faults.fail(.write, occurrence: 2, with: .failure, message: "disk full")

        do {
            try await session.upload(data: big, toRemotePath: "/fresh.bin", onProgress: nil)
            XCTFail("写到一半失败应当报错")
        } catch {}

        try assertOnly([])
    }

    func testCancelledUploadRemovesTheTemporaryFile() async throws {
        try put("app.conf", "precious")
        faults.delayResponses(of: .write, by: .milliseconds(400))
        let session = session!
        let big = big
        let task = Task { try await session.upload(data: big, toRemotePath: "/app.conf", onProgress: nil) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        _ = try? await task.value
        faults.delayResponses(of: .write, by: nil)

        XCTAssertEqual(try text("app.conf"), "precious")
        // 删临时文件的请求在不继承取消的任务里，等它落地。
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
              (try FileManager.default.contentsOfDirectory(atPath: fileSystem.rootPath)).count > 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try assertOnly(["app.conf"])
    }

    func testEditorSaveGoesThroughTheSameReplacement() async throws {
        try put("notes.md", "draft", mode: 0o600)

        try await session.write("/notes.md", data: Data("final".utf8))

        XCTAssertEqual(try text("notes.md"), "final")
        XCTAssertEqual(try mode("notes.md"), 0o600)
        try assertOnly(["notes.md"])
    }

    /// 临时文件的权限改不过去（服务器不让 fsetstat）：不换，免得 0600 的文件换完成了默认权限。照旧原地写。
    func testPermissionsThatCannotBeCopiedFallBackToInPlace() async throws {
        try put("secret.key", "old", mode: 0o600)
        faults.fail(.fsetstat, with: .permissionDenied, message: "nope")

        try await session.upload(data: Data("new".utf8), toRemotePath: "/secret.key", onProgress: nil)

        XCTAssertEqual(try text("secret.key"), "new")
        XCTAssertEqual(try mode("secret.key"), 0o600)
        try assertOnly(["secret.key"])
    }

    /// 符号链接：换掉链接本身会把它变成普通文件。原地写，写进它指向的文件。
    func testSymlinkTargetIsWrittenThroughTheLink() async throws {
        try put("real.conf", "old")
        try FileManager.default.createSymbolicLink(atPath: local("link.conf").path, withDestinationPath: "real.conf")

        try await session.upload(data: Data("new".utf8), toRemotePath: "/link.conf", onProgress: nil)

        XCTAssertEqual(try text("real.conf"), "new")
        let type = try FileManager.default.attributesOfItem(atPath: local("link.conf").path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "链接还是链接")
        try assertOnly(["real.conf", "link.conf"])
    }

    /// 没有 posix-rename 时绝不先删目标再改名（最后一步失败就两份都没了）：照旧原地写。
    func testWithoutPosixRenameTheTargetIsOverwrittenInPlace() async throws {
        var extensions = SFTPServer.defaultExtensions
        extensions[SFTPExtensionName.posixRename] = nil
        try await start(extensions: extensions)
        try put("app.conf", "old")

        try await session.upload(data: Data("new".utf8), toRemotePath: "/app.conf", onProgress: nil)

        XCTAssertEqual(try text("app.conf"), "new")
        XCTAssertEqual(faults.requestCount(of: .rename), 0)
        XCTAssertEqual(faults.requestCount(of: .remove), 0, "没有删过目标")
        try assertOnly(["app.conf"])
    }

    /// 新文件没有可保留的身份，有没有 posix-rename 都走临时文件：失败时目标位置上什么都不留。
    func testNewFileUploadIsMovedIntoPlace() async throws {
        try await session.upload(data: Data("hello".utf8), toRemotePath: "/fresh.txt", onProgress: nil)

        XCTAssertEqual(try text("fresh.txt"), "hello")
        XCTAssertEqual(faults.requestCount(of: .rename), 1)
        try assertOnly(["fresh.txt"])
    }

    /// 临时文件名按字节拼在目标旁边：不是 UTF-8 的名字也落在同一个目录、同一个名字上。
    /// （APFS 只收合法 UTF-8 的文件名，真文件试不了，这里核拼出来的字节。）
    func testTemporaryPathSitsNextToTheTargetAndIsHidden() {
        let path = SFTPSession.temporaryUploadPath(for: SFTPPath(bytes: Array("/srv/www/".utf8) + [0xFF] + Array("x".utf8)))
        let bytes = Array(path.bytes)
        XCTAssertEqual(Array(bytes.prefix(10)), Array("/srv/www/.".utf8))
        XCTAssertEqual(bytes[10], 0xFF)
        let tail = String(decoding: bytes.suffix(from: 11), as: UTF8.self)
        XCTAssertTrue(tail.hasPrefix("x.uterm-upload-") && tail.hasSuffix(".tmp"), tail)
        XCTAssertNotEqual(SFTPSession.temporaryUploadPath(for: "/a").bytes,
                          SFTPSession.temporaryUploadPath(for: "/a").bytes, "每次随机")
        XCTAssertEqual(Array(SFTPSession.temporaryUploadPath(for: "bare").bytes.prefix(5)), Array(".bare".utf8))
    }
}

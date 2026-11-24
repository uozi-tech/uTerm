import XCTest
import SwiftData
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// 上传与编辑器保存怎么写远端文件：
/// - 目标已经在：原地写，和迁移之前一样（同一个 inode，硬链接、单文件挂载看得到改动；只读文件写不进去）；
/// - 新建文件：先写临时文件再改名，失败、取消、断线时目标位置上什么都不留。
/// 服务端是进程内的测试服务端，背后是本机临时目录（`SFTPLocalFileSystem`），权限、inode、链接都是真的。
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

    private func inode(_ name: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: local(name).path)[.systemFileNumber] as? Int ?? -1
    }

    private func temporaryName(_ name: String) -> String { ".\(name).uterm-upload.tmp" }

    // MARK: - 目标已经在：原地写

    func testOverwriteWritesInPlaceAndKeepsTheInode() async throws {
        try put("app.conf", "old", mode: 0o640)
        let before = try inode("app.conf")

        try await session.upload(data: Data("new".utf8), toRemotePath: "/app.conf", onProgress: nil)

        XCTAssertEqual(try text("app.conf"), "new")
        XCTAssertEqual(try inode("app.conf"), before, "同一个 inode：单文件挂载、开着它的进程看得到改动")
        XCTAssertEqual(try mode("app.conf"), 0o640)
        XCTAssertEqual(faults.requestCount(of: .rename), 0)
        XCTAssertEqual(faults.requestCount(of: .extended(SFTPExtensionName.posixRename)), 0)
        try assertOnly(["app.conf"])
    }

    func testEditorSaveWritesInPlace() async throws {
        try put("notes.md", "draft", mode: 0o600)
        let before = try inode("notes.md")

        try await session.write("/notes.md", data: Data("final".utf8))

        XCTAssertEqual(try text("notes.md"), "final")
        XCTAssertEqual(try inode("notes.md"), before)
        XCTAssertEqual(try mode("notes.md"), 0o600)
        try assertOnly(["notes.md"])
    }

    /// 只读文件和迁移之前一样写不进去（换 inode 的做法只要目录可写就能把它盖掉）。
    func testReadOnlyTargetIsRefusedAsBefore() async throws {
        try put("locked.conf", "keep", mode: 0o444)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: local("locked.conf").path) }

        do {
            try await session.upload(data: Data("new".utf8), toRemotePath: "/locked.conf", onProgress: nil)
            XCTFail("只读文件不该被改")
        } catch {}
        do {
            try await session.write("/locked.conf", data: Data("new".utf8))
            XCTFail("只读文件不该被改")
        } catch {}

        XCTAssertEqual(try text("locked.conf"), "keep")
        try assertOnly(["locked.conf"])
    }

    func testHardLinkStillSharesTheContent() async throws {
        try put("a.conf", "old")
        try FileManager.default.linkItem(at: local("a.conf"), to: local("b.conf"))

        try await session.upload(data: Data("new".utf8), toRemotePath: "/a.conf", onProgress: nil)

        XCTAssertEqual(try text("b.conf"), "new", "硬链接的另一个名字看得到改动")
        XCTAssertEqual(try inode("a.conf"), try inode("b.conf"))
    }

    /// 符号链接：写进它指向的文件，链接还是链接。
    func testSymlinkTargetIsWrittenThroughTheLink() async throws {
        try put("real.conf", "old")
        try FileManager.default.createSymbolicLink(atPath: local("link.conf").path, withDestinationPath: "real.conf")

        try await session.upload(data: Data("new".utf8), toRemotePath: "/link.conf", onProgress: nil)

        XCTAssertEqual(try text("real.conf"), "new")
        let type = try FileManager.default.attributesOfItem(atPath: local("link.conf").path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "链接还是链接")
        try assertOnly(["real.conf", "link.conf"])
    }

    /// 已经在的目标写到一半失败：和迁移之前一样是半截的（有意如此，换来的是不换 inode），但不留临时文件。
    func testFailedOverwriteBehavesAsBeforeAndLeavesNoTemporaryFile() async throws {
        try put("app.conf", "precious")
        faults.fail(.write, occurrence: 2, with: .failure, message: "disk full")

        do {
            try await session.upload(data: big, toRemotePath: "/app.conf", onProgress: nil)
            XCTFail("写到一半失败应当报错")
        } catch {}

        XCTAssertEqual(faults.requestCount(of: .open), 1, "失败之后不再自己重写一遍")
        try assertOnly(["app.conf"])
    }

    // MARK: - 新建文件：临时文件 + 改名

    func testNewFileUploadIsMovedIntoPlace() async throws {
        try await session.upload(data: Data("hello".utf8), toRemotePath: "/fresh.txt", onProgress: nil)

        XCTAssertEqual(try text("fresh.txt"), "hello")
        XCTAssertEqual(faults.requestCount(of: .rename), 1)
        try assertOnly(["fresh.txt"])
    }

    /// 没有 posix-rename 也行：新文件用的是普通 rename（目标本来就不在）。
    func testNewFileWorksWithoutPosixRename() async throws {
        var extensions = SFTPServer.defaultExtensions
        extensions[SFTPExtensionName.posixRename] = nil
        try await start(extensions: extensions)

        try await session.upload(data: Data("hello".utf8), toRemotePath: "/fresh.txt", onProgress: nil)

        XCTAssertEqual(try text("fresh.txt"), "hello")
        try assertOnly(["fresh.txt"])
    }

    func testFailedNewUploadLeavesNothingBehind() async throws {
        faults.fail(.write, occurrence: 2, with: .failure, message: "disk full")

        do {
            try await session.upload(data: big, toRemotePath: "/fresh.bin", onProgress: nil)
            XCTFail("写到一半失败应当报错")
        } catch {}

        try assertOnly([])
    }

    func testCancelledNewUploadLeavesNothingBehind() async throws {
        faults.delayResponses(of: .write, by: .milliseconds(400))
        let session = session!
        let big = big
        let task = Task { try await session.upload(data: big, toRemotePath: "/fresh.bin", onProgress: nil) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        _ = try? await bounded("取消之后的上传任务结束") { try await task.value }
        faults.delayResponses(of: .write, by: nil)

        try assertOnly([])
    }

    /// 断线：临时文件删不掉（没有连接了），但目标位置上没有半截文件；下一次往同一个名字上传时把它清掉。
    func testConnectionLossLeavesOnlyTheTemporaryFileAndTheNextUploadCleansItUp() async throws {
        faults.dropConnection(on: .write, occurrence: 2)

        do {
            try await session.upload(data: big, toRemotePath: "/fresh.bin", onProgress: nil)
            XCTFail("断线应当报错")
        } catch {}
        try assertOnly([temporaryName("fresh.bin")])

        try await start()
        try await session.upload(data: Data("ok".utf8), toRemotePath: "/fresh.bin", onProgress: nil)

        XCTAssertEqual(try text("fresh.bin"), "ok")
        try assertOnly(["fresh.bin"])
    }

    /// 临时文件的位置上有人放了符号链接：不跟着它写、也不删它，直接独占地建目标。
    func testPlantedSymlinkAtTheTemporaryPathIsNeitherFollowedNorRemoved() async throws {
        try put("elsewhere", "untouched")
        try FileManager.default.createSymbolicLink(atPath: local(temporaryName("fresh.txt")).path,
                                                   withDestinationPath: "elsewhere")

        try await session.upload(data: Data("hello".utf8), toRemotePath: "/fresh.txt", onProgress: nil)

        XCTAssertEqual(try text("fresh.txt"), "hello")
        XCTAssertEqual(try text("elsewhere"), "untouched")
        try assertOnly(["fresh.txt", "elsewhere", temporaryName("fresh.txt")])
    }

    /// 临时文件名按字节拼在目标旁边：不是 UTF-8 的名字也落在同一个目录、同一个名字上。
    /// （APFS 只收合法 UTF-8 的文件名，真文件试不了，这里核拼出来的字节。）
    func testTemporaryPathSitsNextToTheTargetAndIsHidden() {
        let path = SFTPSession.temporaryUploadPath(for: SFTPPath(bytes: Array("/srv/www/".utf8) + [0xFF] + Array("x".utf8)))
        XCTAssertEqual(Array(path.bytes), Array("/srv/www/.".utf8) + [0xFF] + Array("x.uterm-upload.tmp".utf8))
        XCTAssertEqual(Array(SFTPSession.temporaryUploadPath(for: "bare").bytes), Array(".bare.uterm-upload.tmp".utf8))
    }

    // MARK: - 长名字

    private func temporaryName(forBytes name: [UInt8]) -> [UInt8] {
        let path = Array(SFTPSession.temporaryUploadPath(for: SFTPPath(bytes: Array("/srv/".utf8) + name)).bytes)
        return Array(path.dropFirst(5))
    }

    /// 237 字节的名字加上前后缀正好 255；再长就截短 + 摘要，永远不超过 255，不同的长名字临时名也不同。
    func testTemporaryNameNeverExceedsTheNameLimit() {
        for length in [237, 238, 255] {
            let name = Array(repeating: UInt8(ascii: "n"), count: length)
            let temporary = temporaryName(forBytes: name)
            XCTAssertLessThanOrEqual(temporary.count, 255, "\(length) 字节的名字")
            XCTAssertTrue(temporary.starts(with: Array(".".utf8)))
            XCTAssertTrue(temporary.reversed().starts(with: Array(".uterm-upload.tmp".utf8).reversed()))
        }
        XCTAssertEqual(temporaryName(forBytes: Array(repeating: UInt8(ascii: "n"), count: 237)).count, 255,
                       "237 字节不用截")
        let a = Array(repeating: UInt8(ascii: "n"), count: 250) + Array("a".utf8)
        let b = Array(repeating: UInt8(ascii: "n"), count: 250) + Array("b".utf8)
        XCTAssertNotEqual(temporaryName(forBytes: a), temporaryName(forBytes: b), "前面一样的两个长名字撞到同一个临时文件")
    }

    /// 80 个汉字（240 字节）：截短落在字符边界上，临时名仍是合法 UTF-8。
    func testLongCJKNameIsTruncatedOnACharacterBoundary() {
        let name = Array(String(repeating: "汉", count: 80).utf8)
        let temporary = temporaryName(forBytes: name)
        XCTAssertLessThanOrEqual(temporary.count, 255)
        XCTAssertNotNil(String(validating: temporary, as: UTF8.self))
    }

    /// 238 与 255 字节的新文件照样走临时文件 + 改名（以前临时名超长，退成直接写目标，断线时留下半截）。
    func testLongNewFileNamesStillUseTheTemporaryFile() async throws {
        for length in [237, 238, 255] {
            let name = String(repeating: "n", count: length - 4) + ".txt"
            let before = faults.requestCount(of: .rename)
            try await session.upload(data: Data("hello".utf8), toRemotePath: "/" + name, onProgress: nil)
            XCTAssertEqual(try text(name), "hello")
            XCTAssertEqual(faults.requestCount(of: .rename), before + 1, "\(length) 字节的名字没走改名")
            try FileManager.default.removeItem(at: local(name))
        }
        try assertOnly([])
    }

    /// 新文件直接建目标时，只有「已经有人建了」才退回原地写；别的错误照实报，不再原地写一遍。
    func testDirectNewFileWriteDoesNotFallBackOnUnrelatedErrors() async throws {
        // 让临时文件与目标的独占创建都拒绝（权限），原地写那一下要是还发了就会多一次 open。
        faults.fail(.open, occurrence: 1, times: 3, with: .permissionDenied, message: "denied")
        do {
            try await session.upload(data: Data("x".utf8), toRemotePath: "/fresh.txt", onProgress: nil)
            XCTFail("权限不够应当报错")
        } catch {}
        XCTAssertEqual(faults.requestCount(of: .open), 2, "临时文件一次、目标一次，不该再原地写")
        try assertOnly([])
    }
}


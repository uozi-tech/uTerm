import XCTest
import SwiftData
@testable import Citadel
@testable import uTerm
@testable import USSHKit

/// 文件组 handler 的行为闸：十个动作的正常路径、上限、错误映射、门禁。
///
/// 连接面全部走替身 —— `HostConnectionSpec.keychainOverride` 顶掉真实钥匙串
///（测试宿主的钥匙串里当然没有这台主机的密码，`errSecMissingEntitlement` 会让用例
/// 在还没走到被测逻辑时就失败），`FakePool` 直接回一个 `MockSFTP`，
/// 所以整套用例不碰网络、不读 keychain。
@MainActor
final class ControlSFTPHandlerTests: XCTestCase {

    // MARK: - 替身

    private actor FakePool: ControlConnectionPooling {
        private let session: any SFTPProviding
        private var failure: Error?
        private(set) var sftpRequests: [UUID] = []
        /// 借还必须配平 —— 漏还等于把池里的一个名额烧掉。
        private(set) var borrowed = 0
        private(set) var returned = 0

        init(session: any SFTPProviding) { self.session = session }

        func failNext(_ error: Error) { failure = error }

        func executor(
            for host: HostConnectionSpec,
            maxLines: Int,
            maxBytes: Int
        ) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("测试替身不提供 exec 通道")
        }

        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            if let failure { throw failure }
            sftpRequests.append(host.id)
            borrowed += 1
            return session
        }

        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {
            returned += 1
        }

        func disconnect(hostID: UUID) async {}
        func disconnectAll() async {}
        func heldHostIDs() async -> [UUID] { [] }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? { nil }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {}
        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {
            throw ControlConnectError.connectFailed("测试替身不提供 exec 通道")
        }
    }

    /// 顶掉真实钥匙串：`HostConnectionSpec.resolve` 要读密码，测试宿主里没有。
    private struct StubKeychain: KeychainReading {
        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            kind == .password ? "pw" : nil
        }
    }

    // MARK: - 夹具

    private var container: ModelContainer!
    private var settings: ControlSettings!
    private var pool: FakePool!
    private var sftp: MockSFTP!
    private var handler: ControlHandler!
    private var profile: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        profile = ServerProfile()
        profile.name = "prod-web"
        profile.host = "192.0.2.10"     // TEST-NET-1：本套用例绝不真正连接
        profile.username = "deploy"
        container.mainContext.insert(profile)
        try container.mainContext.save()

        sftp = MockSFTP()
        pool = FakePool(session: sftp)
        settings = ControlSettings(defaults: Self.freshDefaults())
        settings.isEnabled = true
        settings.allowMutations = true
        handler = ControlHandler(
            settings: settings,
            modelContainer: container,
            forwardingCoordinator: ForwardingCoordinator(),
            pool: pool,
            registry: TerminalSessionRegistry())

        HostConnectionSpec.keychainOverride = StubKeychain()
    }

    override func tearDown() async throws {
        HostConnectionSpec.keychainOverride = nil
        handler = nil
        try await super.tearDown()
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "ControlSFTPHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func request(
        _ action: ControlAction,
        path: String? = nil,
        newPath: String? = nil,
        mode: String? = nil,
        contentBase64: String? = nil,
        maxBytes: Int? = nil,
        offset: Int64? = nil,
        length: Int? = nil,
        force: Bool? = nil,
        host: String? = "prod-web"
    ) -> ControlRequest {
        ControlRequest(
            id: "t",
            action: action,
            host: host,
            maxBytes: maxBytes,
            path: path,
            newPath: newPath,
            mode: mode,
            contentBase64: contentBase64,
            offset: offset,
            length: length,
            force: force)
    }

    // MARK: - 正常路径（十个动作）

    func testListUsesRealPathWhenPathOmitted() async throws {
        let entry = RemoteEntry(
            name: "app.log", posixPermissions: 0o100_644, size: 12,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            uid: 501, gid: 20, ownerName: "deploy", groupName: "staff")
        await sftp.setTree(["/home/user": [entry]])   // MockSFTP.realPath(".") == "/home/user"

        let response = await handler.handle(request(.sftpLs))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.entries?.count, 1)
        let first = try XCTUnwrap(response.entries?.first)
        XCTAssertEqual(first.name, "app.log")
        XCTAssertFalse(first.isDirectory)
        XCTAssertFalse(first.isSymlink)
        XCTAssertEqual(first.size, 12)
        XCTAssertEqual(first.permissions, 0o100_644)
        XCTAssertEqual(first.ownerName, "deploy")
        XCTAssertNotNil(first.modifiedAt)
    }

    func testListPassesExplicitPathThrough() async throws {
        let entry = RemoteEntry(name: "sub", posixPermissions: 0o040_755,
                                size: nil, modifiedAt: nil)
        await sftp.setTree(["/var/log": [entry]])

        let response = await handler.handle(request(.sftpLs, path: "/var/log"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.entries?.first?.name, "sub")
        XCTAssertEqual(response.entries?.first?.isDirectory, true)
    }

    func testStatReturnsSizeAndISOTime() async throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        await sftp.setFile("/etc/hosts", data: Data(repeating: 0x41, count: 33), mtime: when)

        let response = await handler.handle(request(.sftpStat, path: "/etc/hosts"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.stat?.path, "/etc/hosts")
        XCTAssertEqual(response.stat?.size, 33)
        XCTAssertEqual(response.stat?.modifiedAt,
                       ISO8601DateFormatter().string(from: when))
    }

    /// `stat` 要带权限位与类型 —— 只有 size + mtime 时，模型看完一次 `stat` 还是
    /// 不知道这是文件还是目录、能不能写。
    func testStatCarriesRawModeAndKind() async throws {
        await sftp.setFile("/etc/hosts", data: Data(count: 3), mtime: Date())
        await sftp.setStatPermissions("/etc/hosts", 0o100_644)

        let response = await handler.handle(request(.sftpStat, path: "/etc/hosts"))

        XCTAssertTrue(response.ok, response.message)
        // 原始 mode（含类型位），与 `ls` 的 permissions 同义；客户端自己 & 0o7777。
        XCTAssertEqual(response.stat?.permissions, 0o100_644)
        XCTAssertEqual(response.stat?.kind, "file")
    }

    func testStatOmitsModeWhenServerDidNotSendIt() async throws {
        await sftp.setFile("/etc/hosts", data: Data(count: 3), mtime: Date())
        let response = await handler.handle(request(.sftpStat, path: "/etc/hosts"))
        XCTAssertNil(response.stat?.permissions)
        XCTAssertNil(response.stat?.kind, "宁可不说，也不谎称是普通文件")
    }

    func testKindFromModeTypeBits() {
        XCTAssertEqual(ControlFilePayloadBuilder.kind(mode: 0o100_644), "file")
        XCTAssertEqual(ControlFilePayloadBuilder.kind(mode: 0o040_755), "directory")
        XCTAssertEqual(ControlFilePayloadBuilder.kind(mode: 0o120_777), "symlink")
        XCTAssertEqual(ControlFilePayloadBuilder.kind(mode: 0o010_644), "other")
        XCTAssertNil(ControlFilePayloadBuilder.kind(mode: nil))
    }

    func testCatReturnsTextForUTF8() async throws {
        await sftp.setFile("/etc/motd", data: Data("你好 uTerm\n".utf8), mtime: Date())

        let response = await handler.handle(request(.sftpCat, path: "/etc/motd"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.isUTF8, true)
        XCTAssertEqual(response.file?.text, "你好 uTerm\n")
        XCTAssertNil(response.file?.base64)
        XCTAssertEqual(response.file?.truncated, false)
    }

    func testCatReturnsBase64ForBinary() async throws {
        let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x80])
        await sftp.setFile("/tmp/blob.bin", data: binary, mtime: Date())

        let response = await handler.handle(request(.sftpCat, path: "/tmp/blob.bin"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.isUTF8, false)
        XCTAssertNil(response.file?.text)
        XCTAssertEqual(response.file?.base64, binary.base64EncodedString())
        XCTAssertEqual(response.file?.bytes, 5)
    }

    /// `--max-bytes` 只能调小、不能调大，且超过本次上限时先 stat 后拒（不先拉）。
    func testCatRejectsFileLargerThanRequestedLimit() async throws {
        await sftp.setFile("/tmp/big", data: Data(repeating: 0x42, count: 4096), mtime: Date())

        let response = await handler.handle(
            request(.sftpCat, path: "/tmp/big", maxBytes: 1024))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_too_large.rawValue)
        let bounded = await sftp.boundedDownloads
        XCTAssertTrue(bounded.isEmpty, "超限应在 stat 后就拒，不该发起下载")
    }

    /// `truncated` 的判定口径：stat 的大小 > 实际拿到的字节数。
    func testPayloadMarksTruncatedWhenDeclaredSizeExceedsData() {
        let payload = ControlFilePayloadBuilder.payload(
            path: "/tmp/x", data: Data("head".utf8), declaredSize: 4096)
        XCTAssertTrue(payload.truncated)
        XCTAssertEqual(payload.bytes, 4)

        let full = ControlFilePayloadBuilder.payload(
            path: "/tmp/x", data: Data("head".utf8), declaredSize: 4)
        XCTAssertFalse(full.truncated)

        let unknown = ControlFilePayloadBuilder.payload(
            path: "/tmp/x", data: Data("head".utf8), declaredSize: nil)
        XCTAssertFalse(unknown.truncated, "拿不到 stat 时宁可少报也不谎报")
    }

    func testGetRejectsOversizedFileBeforeDownloading() async throws {
        await sftp.setFile("/tmp/huge",
                           data: Data(repeating: 0, count: ControlProtocol.maxFileBytes + 1),
                           mtime: Date())

        let response = await handler.handle(request(.sftpGet, path: "/tmp/huge"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_too_large.rawValue)
        let bounded = await sftp.boundedDownloads
        XCTAssertTrue(bounded.isEmpty, "先 stat 再决定：不该先把 8 MiB 拉进内存")
    }

    func testGetReturnsPayloadWithinLimit() async throws {
        await sftp.setFile("/tmp/ok", data: Data("payload".utf8), mtime: Date())

        let response = await handler.handle(request(.sftpGet, path: "/tmp/ok"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.text, "payload")
        let bounded = await sftp.boundedDownloads
        XCTAssertEqual(bounded.first?.maximumBytes, ControlProtocol.maxFileBytes)
    }

    func testPutDecodesBase64AndWritesAtOffsetZero() async throws {
        let content = Data("hello world".utf8)
        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt",
                    contentBase64: content.base64EncodedString()))

        XCTAssertTrue(response.ok, response.message)
        let writes = await sftp.rangeWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.path, "/tmp/out.txt")
        XCTAssertEqual(writes.first?.offset, 0)
        XCTAssertEqual(writes.first?.bytes, content.count)
        XCTAssertEqual(writes.first?.mode, .create, "缺省档是 create —— 不覆盖既有文件")
        // 响应里回报本次写入的字节数（客户端据此累加进度）。
        XCTAssertEqual(response.file?.path, "/tmp/out.txt")
        XCTAssertEqual(response.file?.bytes, content.count)
        XCTAssertNil(response.file?.text)
        XCTAssertNil(response.file?.base64)
        XCTAssertEqual(response.file?.truncated, false)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, content)
    }

    // MARK: - put：offset / mode / force

    /// 默认 `create` 撞上已存在的文件 → `file_exists`，文件内容一个字节都不许动。
    func testPutRefusesToOverwriteByDefault() async throws {
        await sftp.setFile("/tmp/out.txt", data: Data("old".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt",
                    contentBase64: Data("new".utf8).base64EncodedString()))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_exists.rawValue)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, Data("old".utf8), "被拒的 put 不能改动既有内容")
    }

    /// 没给 mode 时 `force: true` 等价 `mode: overwrite`（与 get 的 --force 对称）。
    func testPutForceIsEquivalentToOverwrite() async throws {
        await sftp.setFile("/tmp/out.txt", data: Data("old-and-long".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt",
                    contentBase64: Data("new".utf8).base64EncodedString(),
                    force: true))

        XCTAssertTrue(response.ok, response.message)
        let writes = await sftp.rangeWrites
        XCTAssertEqual(writes.first?.mode, .overwrite)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, Data("new".utf8), "overwrite 要截断，不能留下旧尾巴")
    }

    /// 显式 `mode` 压过 `force`。
    func testPutExplicitModeWinsOverForce() async throws {
        await sftp.setFile("/tmp/out.txt", data: Data("0123456789".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt", mode: "write",
                    contentBase64: Data("AB".utf8).base64EncodedString(),
                    offset: 4, force: true))

        XCTAssertTrue(response.ok, response.message)
        let writes = await sftp.rangeWrites
        XCTAssertEqual(writes.first?.mode, .write)
        XCTAssertEqual(writes.first?.offset, 4)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, Data("0123AB6789".utf8), "write 档不截断，只覆盖那一段")
    }

    /// 分片并行上传的真实形状：先 overwrite 落第 0 片，其余用 write 按 offset 补齐。
    func testPutChunksAssembleTheWholeFile() async throws {
        let chunkSize = 8
        let whole = Data((0..<40).map { UInt8($0) })
        var responses: [ControlResponse] = []
        for index in stride(from: 0, to: whole.count, by: chunkSize) {
            let slice = whole.subdata(in: index..<min(index + chunkSize, whole.count))
            responses.append(await handler.handle(
                request(.sftpPut, path: "/tmp/big.bin",
                        mode: index == 0 ? "overwrite" : "write",
                        contentBase64: slice.base64EncodedString(),
                        offset: Int64(index))))
        }
        XCTAssertTrue(responses.allSatisfy(\.ok), responses.map(\.message).joined(separator: " | "))
        XCTAssertEqual(responses.map { $0.file?.bytes }, [8, 8, 8, 8, 8])
        let stored = try await sftp.read("/tmp/big.bin")
        XCTAssertEqual(stored, whole)
        let writes = await sftp.rangeWrites
        XCTAssertEqual(writes.map(\.offset), [0, 8, 16, 24, 32])
    }

    func testPutRejectsNegativeOffset() async throws {
        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt",
                    contentBase64: Data("x".utf8).base64EncodedString(),
                    offset: -1))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        let writes = await sftp.rangeWrites
        XCTAssertTrue(writes.isEmpty)
    }

    func testPutRejectsUnknownMode() async throws {
        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt", mode: "append",
                    contentBase64: Data("x".utf8).base64EncodedString()))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(response.message.contains("append"))
    }

    // MARK: - get：offset / length

    func testGetWithOffsetAndLengthReturnsOnlyThatRange() async throws {
        await sftp.setFile("/tmp/big.bin", data: Data("0123456789".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpGet, path: "/tmp/big.bin", offset: 3, length: 4))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.bytes, 4)
        XCTAssertEqual(response.file?.text, "3456")
        XCTAssertEqual(response.file?.truncated, false)
        let reads = await sftp.rangeReads
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first?.offset, 3)
        XCTAssertEqual(reads.first?.length, 4)
    }

    /// 只给 offset：从那里读到单次上限（到 EOF 自然会短）。
    func testGetWithOnlyOffsetReadsToTheEnd() async throws {
        await sftp.setFile("/tmp/big.bin", data: Data("0123456789".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpGet, path: "/tmp/big.bin", offset: 7))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.text, "789")
        XCTAssertEqual(response.file?.bytes, 3)
        let reads = await sftp.rangeReads
        XCTAssertEqual(reads.first?.length, ControlProtocol.maxFileBytes)
    }

    /// 区间读到 EOF 只是「短」，不是 `truncated`（那个字段是给整文件 get 用的）。
    func testGetRangeBeyondEOFIsShortNotTruncated() async throws {
        await sftp.setFile("/tmp/big.bin", data: Data("0123456789".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpGet, path: "/tmp/big.bin", offset: 8, length: 100))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.file?.bytes, 2)
        XCTAssertEqual(response.file?.truncated, false)
    }

    /// 区间 get **不**做整文件的上限检查 —— 大文件正是靠一段段取回来的。
    func testGetRangeSkipsTheWholeFileSizeGate() async throws {
        let huge = Data(repeating: 0x41, count: ControlProtocol.maxFileBytes + 1_000)
        await sftp.setFile("/tmp/huge.bin", data: huge, mtime: Date())

        let whole = await handler.handle(request(.sftpGet, path: "/tmp/huge.bin"))
        XCTAssertFalse(whole.ok, "不带区间的整文件 get 仍要在上限处拒绝")
        XCTAssertEqual(whole.code, ControlErrorCode.file_too_large.rawValue)

        let ranged = await handler.handle(
            request(.sftpGet, path: "/tmp/huge.bin",
                    offset: Int64(ControlProtocol.maxFileBytes), length: 1_000))
        XCTAssertTrue(ranged.ok, ranged.message)
        XCTAssertEqual(ranged.file?.bytes, 1_000)
    }

    func testGetRejectsOversizedLength() async throws {
        await sftp.setFile("/tmp/big.bin", data: Data("x".utf8), mtime: Date())

        let response = await handler.handle(
            request(.sftpGet, path: "/tmp/big.bin",
                    offset: 0, length: ControlProtocol.maxFileBytes + 1))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_too_large.rawValue)
    }

    func testGetRejectsNonPositiveLength() async throws {
        await sftp.setFile("/tmp/big.bin", data: Data("x".utf8), mtime: Date())
        let response = await handler.handle(
            request(.sftpGet, path: "/tmp/big.bin", offset: 0, length: 0))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    /// 借出的 SFTP 会话必须归还，否则池里每主机 4 个名额会被一次次动作烧光。
    func testEverySFTPActionReturnsItsPooledSession() async throws {
        await sftp.setFile("/etc/motd", data: Data("hi".utf8), mtime: Date())
        _ = await handler.handle(request(.sftpStat, path: "/etc/motd"))
        _ = await handler.handle(request(.sftpCat, path: "/etc/motd"))
        _ = await handler.handle(request(.sftpStat, path: "/nope"))  // 失败路径也要还

        let borrowed = await pool.borrowed
        let returned = await pool.returned
        XCTAssertEqual(borrowed, 3)
        XCTAssertEqual(returned, borrowed, "有借无还 = 池里的通道名额被烧掉")
    }

    func testPutRejectsInvalidBase64() async throws {
        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.txt", contentBase64: "这不是 base64!!"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        let uploads = await sftp.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testPutRejectsOversizedContent() async throws {
        let big = Data(repeating: 0x41, count: ControlProtocol.maxFileBytes + 1)
        let response = await handler.handle(
            request(.sftpPut, path: "/tmp/out.bin", contentBase64: big.base64EncodedString()))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_too_large.rawValue)
        let uploads = await sftp.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testMkdirRmRmdirMv() async throws {
        let mkdir = await handler.handle(request(.sftpMkdir, path: "/tmp/d"))
        let rm = await handler.handle(request(.sftpRm, path: "/tmp/f"))
        let rmdir = await handler.handle(request(.sftpRmdir, path: "/tmp/d"))
        let mv = await handler.handle(request(.sftpMv, path: "/tmp/a", newPath: "/tmp/b"))
        XCTAssertTrue(mkdir.ok, mkdir.message)
        XCTAssertTrue(rm.ok, rm.message)
        XCTAssertTrue(rmdir.ok, rmdir.message)
        XCTAssertTrue(mv.ok, mv.message)

        let createdDirs = await sftp.createdDirs
        let removedFiles = await sftp.removedFiles
        let removedDirs = await sftp.removedDirs
        XCTAssertEqual(createdDirs, ["/tmp/d"])
        XCTAssertEqual(removedFiles, ["/tmp/f"])
        XCTAssertEqual(removedDirs, ["/tmp/d"])
        let renames = await sftp.renames
        XCTAssertEqual(renames.first?.from, "/tmp/a")
        XCTAssertEqual(renames.first?.to, "/tmp/b")
    }

    func testMvRequiresNewPath() async throws {
        let response = await handler.handle(request(.sftpMv, path: "/tmp/a"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    /// `mode` 两种写法：八进制串（chmod 日常写法）与十进制整数串。
    func testChmodAcceptsOctalAndDecimalModes() async throws {
        for (path, mode) in [("/tmp/a", "644"), ("/tmp/b", "0755"), ("/tmp/c", "511")] {
            let response = await handler.handle(
                request(.sftpChmod, path: path, mode: mode))
            XCTAssertTrue(response.ok, response.message)
        }

        let changes = await sftp.permissionChanges
        XCTAssertEqual(changes.map(\.mode), [0o644, 0o755, 0o511])
    }

    func testModeParsing() {
        XCTAssertEqual(ControlFileMode.parse("644"), 0o644)
        XCTAssertEqual(ControlFileMode.parse("0644"), 0o644)
        XCTAssertEqual(ControlFileMode.parse("0o755"), 0o755)
        XCTAssertEqual(ControlFileMode.parse("493"), 493, "含 8/9 无法是八进制 → 按十进制读")
        XCTAssertNil(ControlFileMode.parse("rwxr-xr-x"), "符号写法不支持")
        XCTAssertNil(ControlFileMode.parse(""))
        XCTAssertNil(ControlFileMode.parse(nil))
        XCTAssertNil(ControlFileMode.parse("77777"), "超过 0o7777")
    }

    func testChmodRejectsUnparseableMode() async throws {
        let response = await handler.handle(
            request(.sftpChmod, path: "/tmp/a", mode: "u+x"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    // MARK: - 参数与主机

    func testEmptyPathIsInvalidRequest() async throws {
        let response = await handler.handle(request(.sftpStat, path: ""))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testMissingHostIsInvalidRequest() async throws {
        let response = await handler.handle(request(.sftpLs, host: nil))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testUnknownHostIsHostNotFound() async throws {
        let response = await handler.handle(request(.sftpLs, host: "不存在"))
        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
    }

    /// `sftpOnly` 主机**允许**全部文件动作 —— 那条硬规则只挡执行与终端。
    func testSFTPOnlyHostIsAllowed() async throws {
        profile.sftpOnly = true
        try container.mainContext.save()

        let response = await handler.handle(request(.sftpLs, path: "/srv"))
        XCTAssertTrue(response.ok, response.message)
    }

    // MARK: - 门禁

    func testMutationsDisabledBlocksWritesButNotReads() async throws {
        settings.allowMutations = false

        for action in [ControlAction.sftpPut, .sftpMkdir, .sftpRm,
                       .sftpRmdir, .sftpMv, .sftpChmod] {
            let response = await handler.handle(
                request(action, path: "/tmp/x", newPath: "/tmp/y", mode: "644",
                        contentBase64: Data("x".utf8).base64EncodedString()))
            XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue,
                           "\(action.rawValue) 应被改动开关挡住")
        }

        await sftp.setFile("/tmp/r", data: Data("ok".utf8), mtime: Date())
        let cat = await handler.handle(request(.sftpCat, path: "/tmp/r"))
        let stat = await handler.handle(request(.sftpStat, path: "/tmp/r"))
        let ls = await handler.handle(request(.sftpLs))
        XCTAssertTrue(cat.ok, cat.message)
        XCTAssertTrue(stat.ok, stat.message)
        XCTAssertTrue(ls.ok, ls.message)
    }

    func testControlDisabledBlocksEverything() async throws {
        settings.isEnabled = false
        let response = await handler.handle(request(.sftpLs))
        XCTAssertEqual(response.code, ControlErrorCode.control_disabled.rawValue)
    }

    // MARK: - 错误映射

    func testMissingFileMapsToFileNotFound() async throws {
        let response = await handler.handle(request(.sftpStat, path: "/nope"))
        XCTAssertEqual(response.code, ControlErrorCode.file_not_found.rawValue)
    }

    func testListErrorMapsToPermissionDenied() async throws {
        await sftp.setListError(NSError(domain: "MockSFTP", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "permission denied: /root"
        ]))
        let response = await handler.handle(request(.sftpLs, path: "/root"))
        XCTAssertEqual(response.code, ControlErrorCode.permission_denied.rawValue)
    }

    // MARK: - Citadel 真实抛错

    /// Citadel 的 `SFTPClientInboundHandler` 对非 ok/eof 的响应直接
    /// `promise.fail(status)` —— 抛出来的是**裸的 `SFTPMessage.Status`**，
    /// 不是 `SFTPError.errorStatus(_:)`。只认后者时，`sftp rm` 一个不存在的文件
    /// 会落到兜底的 `operation_failed`（真机实测）。
    func testBareSFTPStatusMapsToFileNotFound() async throws {
        await sftp.setRemoveError("/tmp/gone", Self.status(.noSuchFile, "No such file"))

        let response = await handler.handle(request(.sftpRm, path: "/tmp/gone"))

        XCTAssertEqual(response.code, ControlErrorCode.file_not_found.rawValue)
        XCTAssertTrue(response.message.contains("No such file"),
                      "message 要给服务端原话，实得：\(response.message)")
        XCTAssertFalse(response.message.contains("请稍后重试"),
                       "CLI 的 message 不该被 FriendlyError 洗过")
    }

    func testBareSFTPStatusMapsPermissionDenied() {
        XCTAssertEqual(
            ControlFilePayloadBuilder.errorCode(
                for: Self.status(.permissionDenied, "Permission denied")),
            .permission_denied)
    }

    /// `failure` 这类笼统状态仍靠服务端文本兜底（sshd 把 EISDIR 塞在里面）。
    func testSFTPStatusFailureFallsBackToServerText() {
        XCTAssertEqual(
            ControlFilePayloadBuilder.errorCode(for: Self.status(.failure, "Is a directory")),
            .is_directory)
        XCTAssertEqual(
            ControlFilePayloadBuilder.errorCode(for: Self.status(.failure, "Directory not empty")),
            .operation_failed)
    }

    /// 包过一层的那条路径（`SFTPClient.setAttributes`）也要照旧认。
    func testWrappedSFTPErrorStatusStillMaps() {
        let wrapped = SFTPError.errorStatus(Self.status(.noSuchFile, "No such file"))
        XCTAssertEqual(ControlFilePayloadBuilder.errorCode(for: wrapped), .file_not_found)
        XCTAssertTrue(ControlFilePayloadBuilder.errorDetail(for: wrapped).contains("No such file"))
    }

    func testErrorDetailCarriesServerMessageAndCode() {
        let detail = ControlFilePayloadBuilder.errorDetail(
            for: Self.status(.noSuchFile, "No such file"))
        XCTAssertTrue(detail.contains("No such file"), detail)
        XCTAssertTrue(detail.contains("SSH_FX 2"), detail)
    }

    /// `SFTPMessage.Status` 的 memberwise init 是 internal，只有 `@testable import`
    /// 拿得到 —— 这也是本文件 `@testable import Citadel` 的唯一理由。
    private static func status(
        _ code: SFTPStatusCode, _ message: String
    ) -> SFTPMessage.Status {
        SFTPMessage.Status(requestId: 1, errorCode: code, message: message, languageTag: "en")
    }

    func testErrorCodeMapping() {
        let mapper = ControlFilePayloadBuilder.errorCode(for:)

        XCTAssertEqual(mapper(SFTPDownloadLimitExceeded(observedBytes: 99, maximumBytes: 10)),
                       .file_too_large)
        XCTAssertEqual(mapper(NSError(domain: "x", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no such file: /a"])), .file_not_found)
        XCTAssertEqual(mapper(NSError(domain: "x", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Permission denied"])), .permission_denied)
        XCTAssertEqual(mapper(NSError(domain: "x", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Is a directory"])), .is_directory)
        XCTAssertEqual(mapper(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))),
                       .file_not_found)
        XCTAssertEqual(mapper(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))),
                       .permission_denied)
        XCTAssertEqual(mapper(NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))),
                       .is_directory)
        XCTAssertEqual(mapper(NSError(domain: "x", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "directory not empty"])), .operation_failed,
                       "契约里没有这个码 → 落兜底")
    }

    // MARK: - 建连失败

    func testUnknownHostKeyIsReportedWithFingerprint() async throws {
        await pool.failNext(ControlConnectError.hostKeyUnknown(
            fingerprint: "SHA256:abcdef", algorithm: "ssh-ed25519"))

        let response = await handler.handle(request(.sftpLs))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.host_key_unknown.rawValue)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:abcdef")
        XCTAssertEqual(response.hostKey?.algorithm, "ssh-ed25519")
        XCTAssertEqual(response.hostKey?.status, "unknown")
    }

    func testChangedHostKeyIsReported() async throws {
        await pool.failNext(ControlConnectError.hostKeyChanged(
            fingerprint: "SHA256:zzz", algorithm: "ssh-rsa"))

        let response = await handler.handle(request(.sftpLs))
        XCTAssertEqual(response.code, ControlErrorCode.host_key_changed.rawValue)
        XCTAssertEqual(response.hostKey?.status, "changed")
    }

    func testAuthFailureMapsToAuthFailed() async throws {
        await pool.failNext(ControlConnectError.authFailed("密码错误"))
        let response = await handler.handle(request(.sftpLs))
        XCTAssertEqual(response.code, ControlErrorCode.auth_failed.rawValue)
    }

    func testConnectFailureMapsToConnectFailed() async throws {
        await pool.failNext(ControlConnectError.connectFailed("超时"))
        let response = await handler.handle(request(.sftpLs))
        XCTAssertEqual(response.code, ControlErrorCode.connect_failed.rawValue)
    }
}

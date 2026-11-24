import XCTest
import SwiftData
import USSHTestServer
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
        /// 借成功这么多次之后一律抛 `error`（传输中途换不了新会话）。
        private var failAfter: (successes: Int, error: Error)?
        /// 借的次数（含失败的）。
        private(set) var attempts = 0
        func failAfter(successes: Int, with error: Error) { failAfter = (successes, error) }

        func executor(
            for host: HostConnectionSpec,
            maxLines: Int,
            maxBytes: Int
        ) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("测试替身不提供 exec 通道")
        }

        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            attempts += 1
            if let failure { throw failure }
            if let failAfter, borrowed >= failAfter.successes { throw failAfter.error }
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))

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
        maxBytes: Int? = nil,
        force: Bool? = nil,
        ranges: [ControlByteRange]? = nil,
        parallel: Int? = nil,
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
            force: force,
            ranges: ranges,
            parallel: parallel)
    }

    /// 本地临时文件（写好内容）+ 打开的 fd。传输测试把它当成客户端交来的那个 fd。
    private func localFile(_ contents: Data) throws -> (url: URL, fd: Int32) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sftp-handler-\(UUID().uuidString.prefix(8))")
        try contents.write(to: url)
        let fd = open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, fd)
    }

    /// 像 `ControlServer` 那样把 fd 挂进请求上下文再调 handler。fd 的所有权交给 handler
    /// （它负责关）；返回响应与上下文（好查进度账）。
    private func transfer(_ request: ControlRequest, fd: Int32?) async -> (ControlResponse, ControlRequestContext) {
        let context = ControlRequestContext(fileDescriptors: fd.map { [$0] } ?? [])
        let response = await ControlRequestContext.$current.withValue(context) {
            await handler.handle(request)
        }
        context.closeUntaken()
        return (response, context)
    }

    private static func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
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

    // MARK: - get / put：客户端交 fd，引擎并行读写

    func testGetWritesTheWholeRemoteFileIntoThePassedFD() async throws {
        let remote = Self.randomData(150_000)
        await sftp.setFile("/srv/app.tar", data: remote, mtime: Date())
        let local = try localFile(Data())

        let (response, context) = await transfer(request(.sftpGet, path: "/srv/app.tar", parallel: 3), fd: local.fd)

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(try Data(contentsOf: local.url), remote, "引擎经 fd 写出来的内容逐字节相同")
        XCTAssertEqual(response.transfer?.bytes, 150_000)
        XCTAssertEqual(response.transfer?.totalBytes, 150_000)
        XCTAssertEqual(response.transfer?.channels, 3)
        XCTAssertNil(response.file, "文件字节不再走响应")
        let progress = try XCTUnwrap(context.drainProgress())
        let event = try JSONDecoder().decode(ControlProgressEvent.self, from: progress)
        XCTAssertEqual(event.totalBytes, 150_000)
        XCTAssertEqual(event.done.reduce(0) { $0 + $1.length }, 150_000, "进度账覆盖整个文件")
    }

    /// 传输中途借不到新会话、原因是认证失败：不重试（每次重试都是一次失败的登录），也不让别的工作者接着去借。
    func testTransferStopsAllWorkersOnPermanentBorrowFailure() async throws {
        let remote = Data(repeating: 0x5A, count: 25 << 20)    // 4 段（每段 8 MiB）→ 4 个工作者
        await sftp.setFile("/srv/big.bin", data: remote, mtime: Date())
        await pool.failAfter(successes: 1, with: ControlConnectError.authFailed("服务器拒绝了密码"))
        let local = try localFile(Data())

        let (response, _) = await transfer(request(.sftpGet, path: "/srv/big.bin", parallel: 4), fd: local.fd)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.auth_failed.rawValue)
        let attempts = await pool.attempts
        // 先借一次读大小（成功），之后每个工作者至多借一次；以前每个工作者还会重试两次（1 + 4 × 3 = 13）。
        XCTAssertLessThanOrEqual(attempts, 1 + 4)
        XCTAssertTrue(ParallelTransfer.stopsAllWorkers(ControlConnectError.authFailed("x")))
        XCTAssertFalse(ParallelTransfer.stopsAllWorkers(ControlConnectError.connectFailed("x")))
    }

    /// 续传：只补给定的区间，别处一个字节都不动。
    func testGetWithRangesFillsOnlyThoseRanges() async throws {
        let remote = Self.randomData(100_000)
        await sftp.setFile("/srv/a.bin", data: remote, mtime: Date())
        let local = try localFile(Data(count: 100_000))

        let (response, _) = await transfer(
            request(.sftpGet, path: "/srv/a.bin",
                    ranges: [ControlByteRange(offset: 40_000, length: 20_000)]),
            fd: local.fd)

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.transfer?.bytes, 20_000, "只算补的那段")
        let written = try Data(contentsOf: local.url)
        XCTAssertEqual(written.subdata(in: 40_000..<60_000), remote.subdata(in: 40_000..<60_000))
        XCTAssertEqual(written.subdata(in: 0..<40_000), Data(count: 40_000), "区间外不许动")
        let reads = await sftp.rangeReads
        XCTAssertTrue(reads.allSatisfy { $0.offset >= 40_000 && $0.offset < 60_000 }, "只读了那段")
    }

    func testGetRejectsARangeBeyondTheFile() async throws {
        await sftp.setFile("/srv/a.bin", data: Data(count: 10), mtime: Date())
        let local = try localFile(Data())
        let (response, _) = await transfer(
            request(.sftpGet, path: "/srv/a.bin", ranges: [ControlByteRange(offset: 5, length: 10)]),
            fd: local.fd)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testTransferWithoutAPassedFDIsInvalidRequest() async throws {
        await sftp.setFile("/srv/a.bin", data: Data(count: 10), mtime: Date())
        let (get, _) = await transfer(request(.sftpGet, path: "/srv/a.bin"), fd: nil)
        XCTAssertEqual(get.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(get.message.contains("SCM_RIGHTS"), get.message)
        let (put, _) = await transfer(request(.sftpPut, path: "/srv/b.bin"), fd: nil)
        XCTAssertEqual(put.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testParallelOutOfRangeIsInvalidRequest() async throws {
        let local = try localFile(Data())
        let (response, _) = await transfer(
            request(.sftpGet, path: "/srv/a.bin", parallel: ControlProtocol.maxTransferChannels + 1),
            fd: local.fd)
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testGetMissingRemoteFileMapsToFileNotFound() async throws {
        let local = try localFile(Data())
        let (response, _) = await transfer(request(.sftpGet, path: "/nope"), fd: local.fd)
        XCTAssertEqual(response.code, ControlErrorCode.file_not_found.rawValue)
    }

    func testPutReadsThePassedFDIntoTheRemoteFile() async throws {
        let content = Self.randomData(70_000)
        let local = try localFile(content)

        let (response, _) = await transfer(request(.sftpPut, path: "/tmp/out.bin"), fd: local.fd)

        XCTAssertTrue(response.ok, response.message)
        let stored = try await sftp.read("/tmp/out.bin")
        XCTAssertEqual(stored, content)
        XCTAssertEqual(response.transfer?.bytes, 70_000)
        let writes = await sftp.rangeWrites
        XCTAssertEqual(writes.first?.mode, .create, "缺省档是 create —— 不覆盖既有文件")
        XCTAssertTrue(writes.dropFirst().allSatisfy { $0.mode == .write }, "之后一律不截断地并行写")
    }

    /// 默认撞上已存在的文件 → `file_exists`，内容一个字节都不许动。
    func testPutRefusesToOverwriteByDefault() async throws {
        await sftp.setFile("/tmp/out.txt", data: Data("old".utf8), mtime: Date())
        let local = try localFile(Data("new".utf8))

        let (response, _) = await transfer(request(.sftpPut, path: "/tmp/out.txt"), fd: local.fd)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_exists.rawValue)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, Data("old".utf8), "被拒的 put 不能改动既有内容")
    }

    /// `force` 覆盖：要截断，不能留下旧尾巴。
    func testPutForceOverwritesAndTruncates() async throws {
        await sftp.setFile("/tmp/out.txt", data: Data("old-and-long".utf8), mtime: Date())
        let local = try localFile(Data("new".utf8))

        let (response, _) = await transfer(request(.sftpPut, path: "/tmp/out.txt", force: true), fd: local.fd)

        XCTAssertTrue(response.ok, response.message)
        let stored = try await sftp.read("/tmp/out.txt")
        XCTAssertEqual(stored, Data("new".utf8))
    }

    /// 续传上传：只写给定区间，不做 create / overwrite（远端已有内容保留）。
    func testPutWithRangesWritesOnlyThoseRanges() async throws {
        let content = Self.randomData(50_000)
        var partial = content
        partial.replaceSubrange(10_000..<30_000, with: Data(count: 20_000))
        await sftp.setFile("/tmp/out.bin", data: partial, mtime: Date())
        let local = try localFile(content)

        let (response, _) = await transfer(
            request(.sftpPut, path: "/tmp/out.bin",
                    ranges: [ControlByteRange(offset: 10_000, length: 20_000)]),
            fd: local.fd)

        XCTAssertTrue(response.ok, response.message)
        let stored = try await sftp.read("/tmp/out.bin")
        XCTAssertEqual(stored, content, "补完之后整份一致")
        let writes = await sftp.rangeWrites
        XCTAssertTrue(writes.allSatisfy { $0.mode == .write }, "续传不能截断远端已有内容")
    }

    /// **写阶段**失败（磁盘满 / 配额）不能被误报成 `file_exists`。
    ///
    /// `create` 用 EXCL 打开成功之后文件就已经建出来了，此时再 `stat` 一次必然命中 ——
    /// 旧实现据此把「No space left on device」报成 `file_exists`，用户照提示加
    /// `--force` 重传，然后再失败一次。
    func testPutWriteStageFailureIsNotReportedAsFileExists() async throws {
        await sftp.setWriteStageError(NSError(
            domain: NSPOSIXErrorDomain, code: 28,
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]))
        let local = try localFile(Data("payload".utf8))

        let (response, _) = await transfer(request(.sftpPut, path: "/tmp/out.bin"), fd: local.fd)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.operation_failed.rawValue,
                       "写阶段失败是 operation_failed，不是 file_exists")
        XCTAssertTrue(response.message.contains("No space left on device"),
                      "message 要带原话，实际是：\(response.message)")
    }

    /// **打开阶段**失败仍然走「再 stat 一次」的兜底：SFTP v3 撞 EXCL 只回
    /// `SSH_FX_FAILURE` + 依实现而定的文案，没有这层兜底就报不出 `file_exists`。
    func testPutOpenStageFailureStillFallsBackToFileExists() async throws {
        await sftp.setOpenStageError(NSError(
            domain: "sshd", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Failure"]))
        let local = try localFile(Data("payload".utf8))

        let (response, _) = await transfer(request(.sftpPut, path: "/tmp/out.bin"), fd: local.fd)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.file_exists.rawValue)
    }

    /// 传输借了几条会话就还几条（成功、失败都一样）。
    func testTransferReturnsEveryBorrowedSession() async throws {
        await sftp.setFile("/srv/a.bin", data: Self.randomData(80_000), mtime: Date())
        let good = try localFile(Data())
        _ = await transfer(request(.sftpGet, path: "/srv/a.bin", parallel: 4), fd: good.fd)
        let bad = try localFile(Data())
        _ = await transfer(request(.sftpGet, path: "/nope"), fd: bad.fd)

        let borrowed = await pool.borrowed
        let returned = await pool.returned
        XCTAssertGreaterThan(borrowed, 1)
        XCTAssertEqual(returned, borrowed, "有借无还 = 池里的通道名额被烧掉")
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
                request(action, path: "/tmp/x", newPath: "/tmp/y", mode: "644"))
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

    // MARK: - 不是 UTF-8 的文件名（命令行经真实 SFTP 会话）

    /// 命令行的 `ls` 回的是无损写法；把它原样传回 `cat` / `rm`，操作的是那一个文件——几个 GBK 名字有损解码后
    /// 一模一样也不会弄混。用真的 `SFTPSession` 对着进程内测试服务端（内存文件表，能放非 UTF-8 的名字）。
    func testCLIRoundTripsNonUTF8NamesThroughARealSession() async throws {
        let fs = SFTPMemoryFileSystem()
        let first: [UInt8] = [0xB2, 0xE2, 0xCA, 0xD4] + Array(".txt".utf8)
        let second: [UInt8] = [0xB1, 0xA8, 0xB8, 0xE6] + Array(".txt".utf8)
        fs.put(SFTPPath(bytes: Array("/home/test/".utf8) + first), Array("first".utf8))
        fs.put(SFTPPath(bytes: Array("/home/test/".utf8) + second), Array("second".utf8))
        var configuration = SSHTestServer.Configuration(authentication: .acceptAnyone)
        configuration.serveSFTP(fileSystem: fs)
        let server = try await SSHTestServer.start(configuration)
        let verifier = HostKeyVerifier(modelContainer: container)
        let connected = try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"), jumpHostAuth: nil,
            hostKeyVerifier: verifier, hostKeyApprover: { _ in true })
        let session = try await SFTPSession(connected: connected, pacesUploads: false)
        let realHandler = ControlHandler(
            settings: settings, modelContainer: container, forwardingCoordinator: ForwardingCoordinator(),
            pool: FakePool(session: session), registry: TerminalSessionRegistry())
        defer { Task { await session.close(); await server.stop() } }

        let ls = await realHandler.handle(request(.sftpLs, path: "/home/test"))
        XCTAssertTrue(ls.ok, ls.message)
        let names = try XCTUnwrap(ls.entries?.map(\.name))
        XCTAssertEqual(Set(names), [RemoteName.display(first), RemoteName.display(second)])

        let cat = await realHandler.handle(request(.sftpCat, path: "/home/test/" + RemoteName.display(second)))
        XCTAssertTrue(cat.ok, cat.message)
        XCTAssertEqual(cat.file?.text, "second")

        let rm = await realHandler.handle(request(.sftpRm, path: "/home/test/" + RemoteName.display(first)))
        XCTAssertTrue(rm.ok, rm.message)
        XCTAssertNil(fs.contents(SFTPPath(bytes: Array("/home/test/".utf8) + first)))
        XCTAssertEqual(fs.contents(SFTPPath(bytes: Array("/home/test/".utf8) + second)), Array("second".utf8))
    }

    // MARK: - 服务端状态（`SFTPError.status`）

    /// 服务端状态一律是 `SFTPError.status`。Citadel 时代有的路径抛裸的状态消息、有的包一层，
    /// 只认一种时 `sftp rm` 一个不存在的文件会落到兜底的 `operation_failed`（真机实测）。
    func testSFTPStatusMapsToFileNotFound() async throws {
        await sftp.setRemoveError("/tmp/gone", Self.status(.noSuchFile, "No such file"))

        let response = await handler.handle(request(.sftpRm, path: "/tmp/gone"))

        XCTAssertEqual(response.code, ControlErrorCode.file_not_found.rawValue)
        XCTAssertTrue(response.message.contains("No such file"),
                      "message 要给服务端原话，实得：\(response.message)")
        XCTAssertFalse(response.message.contains("请稍后重试"),
                       "CLI 的 message 不该被 FriendlyError 洗过")
    }

    func testSFTPStatusMapsPermissionDenied() {
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

    /// 「文件已存在」按状态码认（SSH_FX_FILE_ALREADY_EXISTS = 11），不再比原始数字。
    func testFileAlreadyExistsStatusMapsToFileExists() {
        XCTAssertEqual(ControlFilePayloadBuilder.errorCode(for: Self.status(.fileAlreadyExists, "")), .file_exists)
        // 写阶段包的那层先剥掉再认。
        let staged = SFTPWriteStageError(stage: .open, underlying: Self.status(.fileAlreadyExists, "exists"))
        XCTAssertEqual(ControlFilePayloadBuilder.errorCode(for: staged), .file_exists)
    }

    /// 下载中途文件变短：USSHCore 报 `shortRead`，不当成功、也不归成「找不到」。
    func testShortReadMapsToOperationFailed() {
        XCTAssertEqual(ControlFilePayloadBuilder.errorCode(for: SFTPError.shortRead(expected: 10, actual: 3)),
                       .operation_failed)
    }

    func testErrorDetailCarriesServerMessageAndCode() {
        let detail = ControlFilePayloadBuilder.errorDetail(
            for: Self.status(.noSuchFile, "No such file"))
        XCTAssertTrue(detail.contains("No such file"), detail)
        XCTAssertTrue(detail.contains("SSH_FX 2"), detail)
    }

    private static func status(_ code: SFTPStatusCode, _ message: String) -> SFTPError {
        .status(code: code, message: message, languageTag: "en")
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

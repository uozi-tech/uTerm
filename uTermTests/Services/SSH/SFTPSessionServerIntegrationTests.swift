import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import SwiftData
import XCTest
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// `SFTPSession` 对着**真的 SFTP 端点**跑一遍：uAppKit 的进程内测试服务端 `USSHTestServer`
/// （走本机 TCP + 真实 SSH 握手 + 真实 SFTP 线格式），背后是下面的内存文件表。
///
/// 为什么值得单独来一趟：`SFTPPipelineTests` 断言的是并发形状，用的是假文件；
/// 只有把按服务器上限切的并发 WRITE / READ 真的压进一条 SSH 通道，才能验证
/// 「同一通道多请求并发」这个前提本身成立（请求号 → 应答不串、
/// 服务端的随机写落到正确 offset、20 MiB 往返 sha256 逐字节一致）。
///
/// 不依赖任何外部 sshd，也不读钥匙串；端口是内核分配的（bind 0）。
final class SFTPSessionServerIntegrationTests: XCTestCase {

    // MARK: - 夹具

    private var server: SSHTestServer!
    private var fs: SFTPMemoryFileSystem!
    private var session: SFTPSession!

    override func setUp() async throws {
        try await super.setUp()
        fs = SFTPMemoryFileSystem()
        server = try await Self.startServer(fs: fs)
        session = try await SFTPSession(connected: try await connect(port: server.port))
    }

    /// 谁来都放行的服务端（只活在本用例里，端口由内核分配）。`maximumPacketSize` 决定它通告的通道窗口（× 64）。
    private static func startServer(fs: SFTPMemoryFileSystem,
                                    maximumPacketSize: Int = 1 << 17,
                                    rekeyLimits: NIOSSHRekeyLimits = .default,
                                    sftp: SFTPServer.Configuration = SFTPServer.Configuration()) async throws -> SSHTestServer {
        var configuration = SSHTestServer.Configuration(
            authentication: .acceptAnyone, maximumPacketSize: maximumPacketSize)
        configuration.rekeyLimits = rekeyLimits
        configuration.serveSFTP(fileSystem: fs, configuration: sftp)
        return try await SSHTestServer.start(configuration)
    }

    /// 连到本机某个端口（服务端本身，或挡在它前面的代理）上的一条新 SSH 连接。
    private func connect(port: Int) async throws -> ConnectedClient {
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        return try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
    }

    override func tearDown() async throws {
        await session?.close()
        session = nil
        await server?.stop()
        server = nil
        try await super.tearDown()
    }

    private func payload(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        // 随机内容：全 0 / 重复模式会让「offset 写错位」这类 bug 蒙混过关。
        while bytes.count < count {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes.prefix(count))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 用例

    /// 20 MiB 上传 → 下载 → sha256 必须逐字节一致。
    ///
    /// 这一条同时压住三件事：切片覆盖完整（少一片就对不上）、并发写落在正确的
    /// offset（错位就对不上）、以及并发读的拼装顺序（乱序也对不上）。
    func testTwentyMebibyteRoundTripKeepsTheSameSHA256() async throws {
        let source = payload(20 * 1_048_576)
        let expected = sha256(source)

        try await session.upload(data: source, toRemotePath: "/home/test/big.bin")

        let stored = try XCTUnwrap(fs.contents("/home/test/big.bin"))
        XCTAssertEqual(stored.count, source.count, "服务端落盘的字节数要与源一致")

        let fetched = try await session.download(remotePath: "/home/test/big.bin")
        XCTAssertEqual(fetched.count, source.count)
        XCTAssertEqual(sha256(fetched), expected, "20 MiB 往返后 sha256 必须一致")
    }

    /// 本地文件流式上传 / 下载（GUI 的传输路径）也走同一条流水线。
    func testStreamingUploadAndDownloadRoundTrip() async throws {
        let source = payload(6 * 1_048_576)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localIn = directory.appendingPathComponent("in.bin")
        let localOut = directory.appendingPathComponent("out.bin")
        try source.write(to: localIn)

        try await session.upload(localURL: localIn, toRemotePath: "/home/test/stream.bin",
                                 onProgress: nil)
        try await session.download(remotePath: "/home/test/stream.bin",
                                   toLocalURL: localOut, onProgress: nil)

        let fetched = try Data(contentsOf: localOut)
        XCTAssertEqual(sha256(fetched), sha256(source))
    }

    /// 服务端每 256 KiB 就换一次钥匙：并行的分片写、整份往返都要跨过几十次重新协商，
    /// 换钥匙期间排队的包不能丢、不能乱序，结果逐字节一致。
    func testParallelTransferSurvivesFrequentRekeys() async throws {
        await session.close()
        await server.stop()
        server = try await Self.startServer(
            fs: fs, rekeyLimits: NIOSSHRekeyLimits(packets: nil, bytes: 256 * 1024))
        session = try await SFTPSession(connected: try await connect(port: server.port))

        let chunk = 1_048_576
        let chunks = (0..<6).map { _ in payload(chunk) }
        let whole = chunks.reduce(into: Data()) { $0.append($1) }
        try await session.writeRange("/home/test/rekey.bin", offset: 0,
                                     data: chunks[0], mode: .overwrite)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1..<chunks.count {
                let data = chunks[index]
                let offset = UInt64(index * chunk)
                group.addTask { [session] in
                    try await session!.writeRange("/home/test/rekey.bin",
                                                  offset: offset, data: data, mode: .write)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(sha256(Data(try XCTUnwrap(fs.contents("/home/test/rekey.bin")))), sha256(whole))

        let fetched = try await session.download(remotePath: "/home/test/rekey.bin")
        XCTAssertEqual(sha256(fetched), sha256(whole))
    }

    /// 分片并行写：多段 `writeRange(.write)` 落在同一文件的不同区间，拼起来完整。
    func testParallelRangeWritesAssembleTheWholeFile() async throws {
        let chunk = 1_048_576
        let chunks = (0..<8).map { _ in payload(chunk) }
        let whole = chunks.reduce(into: Data()) { $0.append($1) }

        // 第 0 片 overwrite（建立/截断），其余 write 档并行补齐。
        try await session.writeRange("/home/test/chunked.bin", offset: 0,
                                     data: chunks[0], mode: .overwrite)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1..<chunks.count {
                let data = chunks[index]
                let offset = UInt64(index * chunk)
                group.addTask { [session] in
                    try await session!.writeRange("/home/test/chunked.bin",
                                                  offset: offset, data: data, mode: .write)
                }
            }
            try await group.waitForAll()
        }

        let fetched = try await session.download(remotePath: "/home/test/chunked.bin")
        XCTAssertEqual(fetched.count, whole.count)
        XCTAssertEqual(sha256(fetched), sha256(whole))
    }

    // MARK: - 下载的数据完整性

    /// 下载到本地文件：字节数必须**等于** stat 报的大小，一个字节都不能少。
    func testDownloadToLocalURLMatchesTheStatSize() async throws {
        let source = payload(9 * 1_048_576)
        fs.put("/home/test/exact.bin", Array(source))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localOut = directory.appendingPathComponent("exact.bin")

        let declared = try await session.stat("/home/test/exact.bin").size
        try await session.download(remotePath: "/home/test/exact.bin",
                                   toLocalURL: localOut, onProgress: nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: localOut.path)
        let localSize = try XCTUnwrap(attributes[.size] as? Int)
        XCTAssertEqual(Int64(localSize), declared, "落地大小必须等于 stat.size")
        XCTAssertEqual(sha256(try Data(contentsOf: localOut)), sha256(source))
    }

    /// 服务端一路短给（SFTP 允许）：客户端补发到读满，内容仍逐字节一致。
    func testDownloadRetriesServerShortReads() async throws {
        let source = payload(2 * 1_048_576)
        fs.put("/home/test/short.bin", Array(source))
        fs.setShortReadBudget(40)   // 前 40 个 READ 只给一半

        let fetched = try await session.download(remotePath: "/home/test/short.bin")

        XCTAssertEqual(fetched.count, source.count)
        XCTAssertEqual(sha256(fetched), sha256(source), "短读补发之后内容要一致")
    }

    /// 服务端在文件中途开始回空（谎报 EOF）：下载必须**失败**，
    /// 而不是回一个「成功」的残缺文件 —— 这正是 12 MiB 下成 116 KiB 的形状。
    func testDownloadFailsInsteadOfSilentlyTruncating() async throws {
        let source = payload(4 * 1_048_576)
        fs.put("/home/test/liar.bin", Array(source))
        fs.setLieAboutEOF(from: 128 * 1_024)

        do {
            let fetched = try await session.download(remotePath: "/home/test/liar.bin")
            XCTFail("服务端中途回空必须抛错，实际拿回了 \(fetched.count) 字节并报成功")
        } catch is SFTPShortReadError {
            // 预期：声明有 4 MiB，读不满就是数据不完整。
        } catch SFTPError.shortRead {
            // 同上（USSHCore 自己读的那几段）。
        }
        fs.setLieAboutEOF(from: nil)
    }

    /// 服务端在文件中途回 0 字节的 DATA（不是 EOF）：协议错误，下载报错——不当成读完了，也不原地一直重读。
    func testZeroLengthDataMidFileFailsTheDownload() async throws {
        fs.put("/home/test/zero.bin", Array(payload(1_048_576)))
        fs.setZeroLengthData(from: 128 * 1_024)
        defer { fs.setZeroLengthData(from: nil) }

        do {
            let fetched = try await session.download(remotePath: "/home/test/zero.bin")
            XCTFail("0 字节的 DATA 必须报错，实际拿回了 \(fetched.count) 字节")
        } catch SFTPError.invalidResponse {
        } catch is SFTPShortReadError {
        } catch SFTPError.shortRead {
        }
        XCTAssertTrue(ParallelTransfer.stopsAllWorkers(SFTPError.invalidResponse("x")),
                      "并行传输碰到它整次失败，不按段重试")
    }

    /// 区间读：读回的就是那一段；越过末尾只是短，不报错。
    func testReadRangeReturnsExactlyThatSlice() async throws {
        let source = payload(3 * 1_048_576)
        try await session.writeRange("/home/test/slice.bin", offset: 0,
                                     data: source, mode: .overwrite)

        let middle = try await session.readRange("/home/test/slice.bin",
                                                 offset: 1_000_000, length: 500_000)
        XCTAssertEqual(middle.count, 500_000)
        XCTAssertEqual(middle, source.subdata(in: 1_000_000..<1_500_000))

        let tail = try await session.readRange("/home/test/slice.bin",
                                               offset: UInt64(source.count - 10),
                                               length: 1_000)
        XCTAssertEqual(tail.count, 10, "越过 EOF 只是短读，不是错误")
    }


    // MARK: - 上传的节奏（和终端共用连接）

    /// 本机 TCP 代理：上行（客户端 → 服务端）按固定速率送，模拟手机上行慢的那一段；下行不限。
    /// 送不完的字节堆在本机的网络栈和代理的接收缓冲里，和真的慢链路一样先来先走。
    private final class ThrottledProxy: @unchecked Sendable {
        private(set) var port: UInt16 = 0
        private let listener: Int32
        private let lock = NSLock()
        private var sockets: [Int32] = []

        init(upstreamPort: Int, uplinkBytesPerSecond: Double) throws {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address -> Bool in
                    Darwin.bind(listener, address, length) == 0 && Darwin.listen(listener, 4) == 0
                        && Darwin.getsockname(listener, address, &length) == 0
                }
            }
            guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
            port = UInt16(bigEndian: address.sin_port)
            let listener = listener
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    let upstream = socket(AF_INET, SOCK_STREAM, 0)
                    var target = sockaddr_in()
                    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    target.sin_family = sa_family_t(AF_INET)
                    target.sin_port = UInt16(upstreamPort).bigEndian
                    target.sin_addr.s_addr = inet_addr("127.0.0.1")
                    let connected = withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                        }
                    }
                    guard connected else { Darwin.close(client); Darwin.close(upstream); continue }
                    for fd in [client, upstream] {
                        var on: Int32 = 1
                        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    }
                    lock.withLock { sockets += [client, upstream] }
                    Thread.detachNewThread { Self.pump(from: client, to: upstream, rate: uplinkBytesPerSecond) }
                    Thread.detachNewThread { Self.pump(from: upstream, to: client, rate: nil) }
                }
            }
        }

        private static func pump(from source: Int32, to destination: Int32, rate: Double?) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let start = Date()
            var sent = 0.0
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes {
                        Darwin.write(destination, $0.baseAddress! + offset, count - offset)
                    }
                    guard written > 0 else { return }
                    offset += written
                }
                if let rate {
                    sent += Double(count)
                    let due = sent / rate - Date().timeIntervalSince(start)
                    if due > 0 { Thread.sleep(forTimeInterval: due) }
                }
            }
            shutdown(destination, SHUT_WR)
        }

        func close() {
            Darwin.close(listener)
            lock.withLock {
                for fd in sockets { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
                sockets.removeAll()
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// 在一条连接上传 `bytes` 字节，同时在同一条连接的另一个 SFTP 通道上每 100 ms 做一次 stat
    ///（代替终端的按键：都是同一条 TCP 上别的通道的小请求），记下起步 0.5 s 之后最慢的一次。
    private func measureUpload(port: Int, paced: Bool, bytes: Int) async throws
        -> (worstWait: Double, throughput: Double) {
        let connected = try await connect(port: port)
        let uploader = try await SFTPSession(connected: connected, pacesUploads: paced)
        let prober = try await SFTPSession(connected: connected)
        let data = payload(bytes)
        let done = Flag()
        let clock = ContinuousClock()
        let started = clock.now
        let upload = Task {
            defer { done.raise() }
            try await uploader.upload(data: data, toRemotePath: "/home/test/upload-\(paced).bin")
        }
        try await Task.sleep(for: .milliseconds(500))
        var worst = Duration.zero
        while !done.isRaised {
            let asked = clock.now
            _ = try await prober.stat("/home/test/probe")
            worst = max(worst, clock.now - asked)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await upload.value
        let elapsed = clock.now - started
        await uploader.close()
        let seconds = { (d: Duration) in Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        XCTAssertEqual(fs.size("/home/test/upload-\(paced).bin"), bytes)
        return (seconds(worst), Double(bytes) / seconds(elapsed))
    }

    /// 回归：上行慢（4 Mbps）时传大文件，不按节奏的话同一条连接上别的通道要等好几秒（终端里就是打不了字）；
    /// 按节奏传时只等零点几秒，上传速率不怎么掉。
    ///
    /// 服务端另起一个、通道窗口开到 2 MiB（OpenSSH 的默认值）：NIO SSH 服务端默认的窗口只有 128 KB，
    /// 一个通道最多只能有这么多没确认的数据进 TCP，堆不出真服务器上的那 2 MiB，测不出问题。
    func testUploadOnASlowUplinkLeavesRoomForOtherChannels() async throws {
        let wideServer = try await startWideWindowServer()
        let serverPort = wideServer.port
        let proxy = try ThrottledProxy(upstreamPort: serverPort, uplinkBytesPerSecond: 500_000)
        defer { proxy.close() }
        fs.put("/home/test/probe", [1])

        let unpaced = try await measureUpload(port: Int(proxy.port), paced: false, bytes: 2_000_000)
        let paced = try await measureUpload(port: Int(proxy.port), paced: true, bytes: 2_000_000)
        print("[pacing] 4 Mbps 上行：不按节奏 最慢 \(unpaced.worstWait) s、\(Int(unpaced.throughput)) B/s；"
              + "按节奏 最慢 \(paced.worstWait) s、\(Int(paced.throughput)) B/s")
        XCTAssertGreaterThan(unpaced.worstWait, 1.0, "前提：不按节奏时别的通道要等好几秒")
        XCTAssertLessThan(paced.worstWait, 0.4, "按节奏传时别的通道最多等零点几秒")
        XCTAssertGreaterThan(paced.throughput, unpaced.throughput * 0.8, "上传速率不能明显掉")
        proxy.close()
        await wideServer.stop()
    }

    /// 通道窗口开到 2 MiB（OpenSSH 的默认值：NIOSSH 的窗口 = 包长 × 64，包长 32 KiB）的服务端，
    /// 文件表与默认的那台共用。
    private func startWideWindowServer(sftp: SFTPServer.Configuration = SFTPServer.Configuration()) async throws -> SSHTestServer {
        try await Self.startServer(fs: fs, maximumPacketSize: 32_768, sftp: sftp)
    }

    /// 快网（本机回环，没有瓶颈）上按节奏传不能比不按节奏慢多少：预算要涨到吃满。
    ///
    /// 两边片长一样（服务器宣告 32 000 B 的上限）：比的是节奏本身的开销。按节奏传的片长本来就压在 32 000 B 以内
    /// （按键不排在大片后面），不按节奏的在 OpenSSH 上会用到 255 KiB 一片，那是片长的差别，不是节奏的。
    func testPacedUploadKeepsUpOnAFastLink() async throws {
        let wideServer = try await startWideWindowServer(sftp: SFTPServer.Configuration(
            limits: SFTPServerLimits(maximumPacketLength: 256 * 1024, maximumReadLength: UInt64(SFTPPipeline.chunkSize),
                                     maximumWriteLength: UInt64(SFTPPipeline.chunkSize), maximumOpenHandles: 0)))
        let port = wideServer.port
        let data = payload(64 * 1_048_576)
        let clock = ContinuousClock()
        func time(paced: Bool) async throws -> Duration {
            let session = try await SFTPSession(connected: try await connect(port: port), pacesUploads: paced)
            let started = clock.now
            try await session.upload(data: data, toRemotePath: "/home/test/fast-\(paced).bin")
            let elapsed = clock.now - started
            await session.close()
            return elapsed
        }
        // 各跑两次取快的，少受机器忙闲影响。
        var unpaced = Duration.seconds(3600), paced = Duration.seconds(3600)
        for _ in 0..<2 {
            unpaced = min(unpaced, try await time(paced: false))
            paced = min(paced, try await time(paced: true))
        }
        print("[pacing] 回环 64 MiB：不按节奏 \(unpaced)，按节奏 \(paced)")
        XCTAssertLessThan(paced, unpaced * 1.3 + .milliseconds(200))
        await wideServer.stop()
    }

    // MARK: - USSHCore 迁移带来的行为

    /// 片长跟服务器走：服务器宣告 255 KiB（`limits@openssh.com`，和 OpenSSH 一样）时，流水线按它切，
    /// 不再写死 32 000；单次 WRITE 超过上限会被 USSHCore 拒绝，所以这条往返本身也证明了没超。
    func testPipelineChunksFollowTheServerLimits() async throws {
        let source = payload(3 * 1_048_576 + 17)
        try await session.upload(data: source, toRemotePath: "/home/test/limits.bin")
        let fetched = try await session.download(remotePath: "/home/test/limits.bin")
        XCTAssertEqual(sha256(fetched), sha256(source))
    }

    /// `create` 档（SSH_FXF_EXCL）撞上已存在的文件：服务器回 SSH_FX_FILE_ALREADY_EXISTS，
    /// 打开阶段的失败带着阶段标记，命令行归成 `file_exists`。（Citadel 的服务端在 delegate 抛错时什么都不回，以前测不了。）
    func testExclusiveCreateOnExistingFileReportsFileExists() async throws {
        fs.put("/home/test/taken.bin", [1, 2, 3])
        do {
            try await session.writeRange("/home/test/taken.bin", offset: 0, data: Data([9]), mode: .create)
            XCTFail("已存在的文件不该被 create 档打开")
        } catch {
            XCTAssertTrue(SFTPWriteStageError.isOpenFailure(error))
            XCTAssertEqual(ControlFilePayloadBuilder.errorCode(for: error), .file_exists)
        }
        XCTAssertEqual(fs.contents("/home/test/taken.bin"), [1, 2, 3], "既有文件不能被截断")
    }

    // MARK: - 不是 UTF-8 的文件名（`RemoteName` 的无损写法）

    /// GBK 编码的「测试」「报告」「附件」：按 UTF-8 有损解码全都成了 `����.txt`。
    private static let gbkNames: [(label: String, bytes: [UInt8])] = [
        ("测试", [0xB2, 0xE2, 0xCA, 0xD4] + Array(".txt".utf8)),
        ("报告", [0xB1, 0xA8, 0xB8, 0xE6] + Array(".txt".utf8)),
        ("附件", [0xB8, 0xBD, 0xBC, 0xFE] + Array(".txt".utf8)),
    ]

    private func path(_ directory: String, _ raw: [UInt8]) -> SFTPPath {
        SFTPPath(bytes: Array(directory.utf8) + [UInt8(ascii: "/")] + raw)
    }

    /// 列出来的名字（显示用的那个）→ 它对应的服务器路径（显示用的写法）。
    private func listed(_ directory: String) async throws -> [String: String] {
        let entries = try await session.list(path: directory)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "列表的标识不能重复")
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.name, RemotePath.join(directory, $0.name)) })
    }

    /// 几个有损解码后一模一样的名字：各显示各的；读、删、改名、覆盖上传都打到对的那个文件上。
    func testCollidingNonUTF8NamesEachResolveToTheirOwnFile() async throws {
        for (label, raw) in Self.gbkNames {
            fs.put(path("/home/test", raw), Array(label.utf8))
        }
        let names = try await listed("/home/test")
        XCTAssertEqual(names.count, 3)
        for (label, raw) in Self.gbkNames {
            let display = RemoteName.display(raw)
            let remote = try XCTUnwrap(names[display], "\(label) 应列成 \(display)")
            let downloaded = try await session.download(remotePath: remote)
            XCTAssertEqual(downloaded, Data(label.utf8), "\(label) 读到了别的文件")
        }

        // 删掉「报告」：只少它一个，重新列出来另外两个照旧。
        let report = RemotePath.join("/home/test", RemoteName.display(Self.gbkNames[1].bytes))
        try await session.removeFile(report)
        XCTAssertNil(fs.contents(path("/home/test", Self.gbkNames[1].bytes)))
        XCTAssertNotNil(fs.contents(path("/home/test", Self.gbkNames[0].bytes)))
        XCTAssertNotNil(fs.contents(path("/home/test", Self.gbkNames[2].bytes)))
        let afterDelete = try await listed("/home/test")
        XCTAssertEqual(Set(afterDelete.keys), [RemoteName.display(Self.gbkNames[0].bytes),
                                               RemoteName.display(Self.gbkNames[2].bytes)])

        // 覆盖上传「附件」：只有它变了。
        let attachment = RemotePath.join("/home/test", RemoteName.display(Self.gbkNames[2].bytes))
        try await session.upload(data: Data("new".utf8), toRemotePath: attachment)
        XCTAssertEqual(fs.contents(path("/home/test", Self.gbkNames[2].bytes)), Array("new".utf8))
        XCTAssertEqual(fs.contents(path("/home/test", Self.gbkNames[0].bytes)), Array("测试".utf8))

        // 「测试」改名成一个正常的名字：原样字节的那个文件被改了名，重新列出来对得上。
        let test = RemotePath.join("/home/test", RemoteName.display(Self.gbkNames[0].bytes))
        try await session.rename(test, to: "/home/test/renamed.txt")
        XCTAssertNil(fs.contents(path("/home/test", Self.gbkNames[0].bytes)))
        XCTAssertEqual(fs.contents("/home/test/renamed.txt"), Array("测试".utf8))
        let afterRename = try await listed("/home/test")
        XCTAssertEqual(Set(afterRename.keys), ["renamed.txt", RemoteName.display(Self.gbkNames[2].bytes)])
    }

    /// 不是 UTF-8 的目录套着不是 UTF-8 的文件：一层层进得去，读得到。
    func testNestedNonUTF8DirectoriesResolve() async throws {
        let outer = path("/home/test", [0xC4, 0xBF, 0xC2, 0xBC])                 // GBK「目录」
        let inner = SFTPPath(bytes: outer.bytes + [UInt8(ascii: "/"), 0xD7, 0xD3])  // GBK「子」
        fs.makeDirectory(outer)
        fs.makeDirectory(inner)
        fs.put(SFTPPath(bytes: inner.bytes + [UInt8(ascii: "/")] + Self.gbkNames[0].bytes), Array("deep".utf8))

        let top = try await session.list(path: "/home/test")
        let outerName = try XCTUnwrap(top.first { $0.isDirectory }?.name)
        XCTAssertEqual(outerName, RemoteName.display(outer.bytes.suffix(4)))
        let level1 = RemotePath.join("/home/test", outerName)
        let level1Entries = try await session.list(path: level1)
        let innerName = try XCTUnwrap(level1Entries.first { $0.isDirectory }?.name)
        let level2 = RemotePath.join(level1, innerName)
        let level2Entries = try await session.list(path: level2)
        let fileName = try XCTUnwrap(level2Entries.first?.name)
        let downloaded = try await session.download(remotePath: RemotePath.join(level2, fileName))
        XCTAssertEqual(downloaded, Data("deep".utf8))
    }

    /// 名字里真有 U+FFFD（合法 UTF-8）和一个非法字节的名字放在一起：两个都分得清。
    func testRealReplacementCharacterNameIsDistinctFromInvalidBytes() async throws {
        let literal = Array("a\u{FFFD}.txt".utf8)
        let invalid: [UInt8] = [UInt8(ascii: "a"), 0xFF] + Array(".txt".utf8)
        fs.put(path("/home/test", literal), Array("literal".utf8))
        fs.put(path("/home/test", invalid), Array("invalid".utf8))
        let names = try await listed("/home/test")
        XCTAssertEqual(names.count, 2)
        XCTAssertNotNil(names["a\u{FFFD}.txt"], "合法的名字原样显示")
        let literalData = try await session.download(remotePath: "/home/test/a\u{FFFD}.txt")
        XCTAssertEqual(literalData, Data("literal".utf8))
        let invalidData = try await session.download(remotePath: try XCTUnwrap(names[RemoteName.display(invalid)]))
        XCTAssertEqual(invalidData, Data("invalid".utf8))
    }

    /// 末尾带斜杠的目录照样列得出、拼得回去（转义不碰斜杠）。
    func testTrailingSlashDirectoryListsAndResolves() async throws {
        fs.put(path("/home/test", Self.gbkNames[0].bytes), [1])
        let entries = try await session.list(path: "/home/test/")
        let name = try XCTUnwrap(entries.first?.name)
        let size = try await session.stat(RemotePath.join(RemotePath.normalized("/home/test/"), name)).size
        XCTAssertEqual(size, 1)
    }

    // MARK: - 服务器宣告的单请求上限

    /// 宣告离谱的大上限（64 MiB）与很小的上限（1 KiB）：往返都完整，前者不会退化成停等、后者每片不超。
    func testHugeAndTinyAdvertisedLimitsRoundTrip() async throws {
        for limit: UInt64 in [64 << 20, 1024] {
            let server = try await Self.startServer(fs: fs, sftp: SFTPServer.Configuration(
                limits: SFTPServerLimits(maximumPacketLength: 256 * 1024, maximumReadLength: limit,
                                         maximumWriteLength: limit, maximumOpenHandles: 0)))
            let limited = try await SFTPSession(connected: try await connect(port: server.port), pacesUploads: false)
            let source = payload(limit > 1 << 20 ? 3 << 20 : 64 * 1024)
            try await limited.upload(data: source, toRemotePath: "/home/test/limit-\(limit).bin")
            let fetched = try await limited.download(remotePath: "/home/test/limit-\(limit).bin")
            XCTAssertEqual(sha256(fetched), sha256(source), "上限 \(limit)")
            await limited.close()
            await server.stop()
        }
    }
}

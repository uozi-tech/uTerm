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

    // MARK: - 进程内 SFTP 服务端

    /// 内存文件表，按路径的**原样字节**存（非 UTF-8 的名字也能放）。服务端的请求与测试都经它读写，故用锁保护。
    private final class MemoryFileSystem: SFTPServerFileSystem, @unchecked Sendable {
        private let lock = NSLock()
        private var files: [SFTPPath: [UInt8]] = [:]
        private var directories: Set<SFTPPath> = ["/home/test"]
        /// 还要短给几次（SFTP 允许服务端少给，客户端必须补发）。
        private var shortReadBudget = 0
        /// 从这个 offset 起一律回空 —— 模拟服务端在文件中途谎报 EOF。
        private var lieAboutEOFFrom: Int?

        func setShortReadBudget(_ count: Int) {
            lock.withLock { shortReadBudget = count }
        }

        func setLieAboutEOF(from offset: Int?) {
            lock.withLock { lieAboutEOFFrom = offset }
        }

        func read(_ path: SFTPPath, at offset: Int, length: Int) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            guard let bytes = files[path], offset < bytes.count else { return [] }
            if let lieAboutEOFFrom, offset >= lieAboutEOFFrom { return [] }
            var end = min(offset + length, bytes.count)
            if shortReadBudget > 0, end - offset > 1 {
                shortReadBudget -= 1
                end = offset + (end - offset) / 2   // 只给一半
            }
            return Array(bytes[offset..<end])
        }

        func write(_ path: SFTPPath, at offset: Int, bytes: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            var existing = files[path] ?? []
            let end = offset + bytes.count
            if existing.count < end {
                existing.append(contentsOf: [UInt8](repeating: 0, count: end - existing.count))
            }
            existing.replaceSubrange(offset..<end, with: bytes)
            files[path] = existing
        }

        func size(_ path: String) -> Int? { size(SFTPPath(path)) }
        func size(_ path: SFTPPath) -> Int? { lock.withLock { files[path]?.count } }
        func contents(_ path: String) -> [UInt8]? { contents(SFTPPath(path)) }
        func contents(_ path: SFTPPath) -> [UInt8]? { lock.withLock { files[path] } }
        func put(_ path: String, _ bytes: [UInt8]) { put(SFTPPath(path), bytes) }
        func put(_ path: SFTPPath, _ bytes: [UInt8]) { lock.withLock { files[path] = bytes } }
        func exists(_ path: SFTPPath) -> Bool { lock.withLock { files[path] != nil } }

        // MARK: SFTPServerFileSystem

        func realPath(_ path: SFTPPath) async throws -> SFTPPath {
            path.bytes.first == UInt8(ascii: "/") ? path : SFTPPath("/home/test").appending(path)
        }

        func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes {
            try lock.withLock {
                if let bytes = files[path] {
                    return SFTPFileAttributes(size: UInt64(bytes.count), permissions: 0o100644)
                }
                if directories.contains(path) { return SFTPFileAttributes(permissions: 0o040755) }
                throw SFTPServerStatusError.noSuchFile()
            }
        }

        func openFile(_ path: SFTPPath, flags: SFTPOpenFlags,
                      attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
            try lock.withLock {
                let exists = files[path] != nil
                if flags.contains(.exclusive), exists {
                    throw SFTPServerStatusError(.fileAlreadyExists, "File exists")
                }
                if !exists, !flags.contains(.create) { throw SFTPServerStatusError.noSuchFile() }
                if flags.contains(.truncate) || !exists { files[path] = [] }
            }
            return MemoryFile(path: path, fs: self)
        }

        func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory {
            let prefix = path.bytes.last == UInt8(ascii: "/") ? path.bytes : path.bytes + [UInt8(ascii: "/")]
            let entries: [SFTPDirectoryEntry] = lock.withLock {
                files.compactMap { file, bytes in
                    guard file.bytes.starts(with: prefix) else { return nil }
                    let name = Array(file.bytes.dropFirst(prefix.count))
                    guard !name.isEmpty, !name.contains(UInt8(ascii: "/")) else { return nil }
                    return SFTPDirectoryEntry(name: SFTPPath(bytes: name), longname: "",
                                              attributes: SFTPFileAttributes(size: UInt64(bytes.count),
                                                                             permissions: 0o100644))
                }
            }
            return MemoryDirectory(entries: entries)
        }

        func removeFile(_ path: SFTPPath) async throws {
            try lock.withLock {
                guard files.removeValue(forKey: path) != nil else { throw SFTPServerStatusError.noSuchFile() }
            }
        }

        func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws {
            _ = lock.withLock { directories.insert(path) }
        }

        func removeDirectory(_ path: SFTPPath) async throws {
            _ = lock.withLock { directories.remove(path) }
        }

        func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
            try lock.withLock {
                guard let bytes = files[oldPath] else { throw SFTPServerStatusError.noSuchFile() }
                if files[newPath] != nil, !replacingExisting { throw SFTPServerStatusError.failure("File exists") }
                files[oldPath] = nil
                files[newPath] = bytes
            }
        }
    }

    private struct MemoryFile: SFTPServerFile {
        let path: SFTPPath
        let fs: MemoryFileSystem

        func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
            let bytes = fs.read(path, at: Int(offset), length: length)
            return bytes.isEmpty ? nil : ByteBuffer(bytes: bytes)
        }

        func write(_ data: ByteBuffer, at offset: UInt64) async throws {
            fs.write(path, at: Int(offset), bytes: Array(data.readableBytesView))
        }

        func attributes() async throws -> SFTPFileAttributes {
            SFTPFileAttributes(size: UInt64(fs.size(path) ?? 0))
        }

        func close() async throws {}
    }

    private final class MemoryDirectory: SFTPServerDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [SFTPDirectoryEntry]?

        init(entries: [SFTPDirectoryEntry]) { pending = entries }

        func nextBatch() async throws -> [SFTPDirectoryEntry]? {
            lock.withLock {
                defer { pending = nil }
                return pending
            }
        }
    }

    // MARK: - 夹具

    private var server: SSHTestServer!
    private var fs: MemoryFileSystem!
    private var session: SFTPSession!

    override func setUp() async throws {
        try await super.setUp()
        fs = MemoryFileSystem()
        server = try await Self.startServer(fs: fs)
        session = try await SFTPSession(connected: try await connect(port: server.port))
    }

    /// 谁来都放行的服务端（只活在本用例里，端口由内核分配）。`maximumPacketSize` 决定它通告的通道窗口（× 64）。
    private static func startServer(fs: MemoryFileSystem,
                                    maximumPacketSize: Int = 1 << 17) async throws -> SSHTestServer {
        var configuration = SSHTestServer.Configuration(
            authentication: .acceptAnyone, maximumPacketSize: maximumPacketSize)
        configuration.serveSFTP(fileSystem: fs)
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
    private func startWideWindowServer() async throws -> SSHTestServer {
        try await Self.startServer(fs: fs, maximumPacketSize: 32_768)
    }

    /// 快网（本机回环，没有瓶颈）上按节奏传不能比不按节奏慢多少：预算要涨到吃满。
    func testPacedUploadKeepsUpOnAFastLink() async throws {
        let wideServer = try await startWideWindowServer()
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

    /// 服务器上的文件名不是合法 UTF-8：界面显示替换过的名字，拿这个名字回去操作（读、改名、删除）时
    /// 换回原样字节，打到的是那个文件本身。
    func testNonUTF8NamesRoundTripThroughListedEntries() async throws {
        let rawName: [UInt8] = Array("报告-".utf8) + [0xB1, 0xA8, 0xB8, 0xE6] + Array(".txt".utf8)   // GBK 残片
        let rawPath = SFTPPath(bytes: Array("/home/test/".utf8) + rawName)
        XCTAssertFalse(rawPath.isLosslessUTF8)
        fs.put(rawPath, Array("hello".utf8))

        let entries = try await session.list(path: "/home/test")
        let entry = try XCTUnwrap(entries.first { $0.name.hasPrefix("报告-") })
        XCTAssertTrue(entry.name.contains("\u{FFFD}"), "显示用的名字里非法字节被替换：\(entry.name)")
        let displayPath = RemotePath.join("/home/test", entry.name)

        let downloaded = try await session.download(remotePath: displayPath)
        XCTAssertEqual(downloaded, Data("hello".utf8))
        let size = try await session.stat(displayPath).size
        XCTAssertEqual(size, 5)

        try await session.rename(displayPath, to: "/home/test/renamed.txt")
        XCTAssertFalse(fs.exists(rawPath))
        XCTAssertEqual(fs.contents("/home/test/renamed.txt"), Array("hello".utf8))
    }
}

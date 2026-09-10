import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import SwiftData
import XCTest
@testable import Citadel
@testable import uTerm
@testable import USSHKit

/// `SFTPSession` 对着**真的 SFTP 端点**跑一遍：Citadel 自带的 SFTP server（进程内、
/// 走本机 TCP + 真实 SSH 握手 + 真实 SFTP 线格式）。
///
/// 为什么值得单独来一趟：`SFTPPipelineTests` 断言的是并发形状，用的是假文件；
/// 只有把 32 000 B 的并发 WRITE / READ 真的压进一条 SSH 通道，才能验证
/// 「同一通道多请求并发」这个前提本身成立（requestId → promise 映射不串、
/// 服务端的随机写落到正确 offset、20 MiB 往返 sha256 逐字节一致）。
///
/// 不依赖任何外部 sshd，也不读钥匙串；端口是内核分配的（bind 0）。
final class SFTPSessionServerIntegrationTests: XCTestCase {

    // MARK: - 进程内 SFTP 服务端

    /// 内存文件表。服务端的 handle 与测试都经它读写，故用锁保护（NIO 线程会碰）。
    private final class MemoryFileSystem: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: [UInt8]] = [:]

        func read(_ path: String, at offset: Int, length: Int) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            guard let bytes = files[path], offset < bytes.count else { return [] }
            return Array(bytes[offset..<min(offset + length, bytes.count)])
        }

        func write(_ path: String, at offset: Int, bytes: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            var existing = files[path] ?? []
            let end = offset + bytes.count
            if existing.count < end {
                existing.append(contentsOf: [UInt8](repeating: 0, count: end - existing.count))
            }
            existing.replaceSubrange(offset..<end, with: bytes)
            files[path] = existing
        }

        func truncate(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            files[path] = []
        }

        func exists(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return files[path] != nil
        }

        func size(_ path: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            return files[path]?.count
        }

        func contents(_ path: String) -> [UInt8]? {
            lock.lock(); defer { lock.unlock() }
            return files[path]
        }

        func put(_ path: String, _ bytes: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            files[path] = bytes
        }
    }

    private struct MemoryFileHandle: SFTPFileHandle {
        let path: String
        let fs: MemoryFileSystem

        func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
            var buffer = ByteBuffer()
            buffer.writeBytes(fs.read(path, at: Int(offset), length: Int(length)))
            return buffer
        }

        func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
            fs.write(path, at: Int(offset), bytes: Array(data.readableBytesView))
            return .ok
        }

        func close() async throws -> SFTPStatusCode { .ok }

        func readFileAttributes() async throws -> SFTPFileAttributes {
            var attributes = SFTPFileAttributes()
            attributes.size = UInt64(fs.size(path) ?? 0)
            return attributes
        }

        func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
    }

    private struct EmptyDirectoryHandle: SFTPDirectoryHandle {
        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] { [] }
    }

    /// 最小可用的 `SFTPDelegate`：open / read / write / stat / realpath 真做，
    /// 其余动作回 `ok` 或 `unsupportedOperation`（本套用例用不到）。
    private struct MemorySFTPDelegate: SFTPDelegate {
        let fs: MemoryFileSystem

        func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
            guard let size = fs.size(path) else {
                throw SFTPError.errorStatus(.init(
                    requestId: 0, errorCode: .noSuchFile,
                    message: "No such file", languageTag: "en"))
            }
            var attributes = SFTPFileAttributes()
            attributes.size = UInt64(size)
            return attributes
        }

        func openFile(_ filePath: String, withAttributes: SFTPFileAttributes,
                      flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
            // ⚠️ 这里**不能**抛错来模拟 EXCL 冲突：Citadel 的
            // `SFTPServerInboundHandler.openFile` 只 `map` 成功路径，没有
            // `whenFailure` —— delegate 一抛错，服务端就什么都不回，客户端的
            // promise 永远不完成（整条用例挂死）。`create` 撞已存在文件的语义
            // 因此只在 `ControlSFTPHandlerTests`（MockSFTP）里验。
            if flags.contains(.truncate) || !fs.exists(filePath) {
                fs.truncate(filePath)
            }
            return MemoryFileHandle(path: filePath, fs: fs)
        }

        func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .ok }
        func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes,
                             context: SSHContext) async throws -> SFTPStatusCode { .ok }
        func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .ok }

        func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            [SFTPPathComponent(filename: "/home/test", longname: "/home/test",
                               attributes: SFTPFileAttributes())]
        }

        func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
            EmptyDirectoryHandle()
        }

        func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String,
                               context: SSHContext) async throws -> SFTPStatusCode { .ok }
        func addSymlink(linkPath: String, targetPath: String,
                        context: SSHContext) async throws -> SFTPStatusCode { .unsupportedOperation }
        func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            throw SFTPError.errorStatus(.init(requestId: 0, errorCode: .unsupportedOperation,
                                              message: "no symlinks", languageTag: "en"))
        }
        func rename(oldPath: String, newPath: String, flags: UInt32,
                    context: SSHContext) async throws -> SFTPStatusCode { .ok }
    }

    /// 任何密码都放行 —— 这台服务端只活在本用例里，端口由内核分配。
    private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    // MARK: - 夹具

    private var server: SSHServer!
    private var fs: MemoryFileSystem!
    private var session: SFTPSession!

    override func setUp() async throws {
        try await super.setUp()
        fs = MemoryFileSystem()
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        server = try await SSHServer.host(
            host: "127.0.0.1",
            port: 0,                       // 0 = 让内核挑一个空闲端口，不跟别的测试抢
            hostKeys: [hostKey],
            authenticationDelegate: AcceptAnyPassword()
        )
        server.enableSFTP(withDelegate: MemorySFTPDelegate(fs: fs))
        let port = try XCTUnwrap(server.channel.localAddress?.port)

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let connected = try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
        session = try await SFTPSession(connected: connected)
    }

    override func tearDown() async throws {
        await session?.close()
        session = nil
        try? await server?.close()
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

}

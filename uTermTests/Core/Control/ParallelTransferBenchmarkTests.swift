import CryptoKit
import Darwin
import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// `ParallelTransfer` 引擎的**压测**：真连接池 → 真 sshd，扫「通道数 × 在途请求 × 窗口」
/// 组合，逐个报下载 / 上传吞吐与内存峰值。第一次下载顺带与远端 `sha256sum` 比对，证明
/// 引擎写出来的字节是对的。需要外部 sshd，**默认跳过**（容器配方见
/// `SFTPConcurrencyBenchmarkTests`，文件 `/root/big` 至少 `UTERM_BENCH_TOTAL_MIB`）。
///
/// 环境变量（加 `TEST_RUNNER_` 前缀）：
/// - `UTERM_BENCH_SSH_PORT`：必填；
/// - `UTERM_BENCH_CONFIGS`：`通道x在途x窗口KiB`，逗号分隔，缺省 `8x64x1024`；
/// - `UTERM_BENCH_TOTAL_MIB`：每个组合传多少，缺省 512；
/// - `UTERM_BENCH_SEGMENT_MIB`：段大小，缺省 8；
/// - `UTERM_BENCH_DIRECTION`：`down` / `up` / `both`，缺省 `down`。
final class ParallelTransferBenchmarkTests: XCTestCase {

    private struct StubKeychain: KeychainReading {
        let password: String
        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            kind == .password ? password : nil
        }
    }

    @MainActor
    func testEngineThroughput() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_BENCH_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_BENCH_SSH_PORT，跳过传输引擎压测")
        }
        let configs = (env["UTERM_BENCH_CONFIGS"] ?? "8x64x1024").split(separator: ",").compactMap { item in
            let parts = item.split(separator: "x").compactMap { Int($0) }
            return parts.count == 3 ? (parts[0], parts[1], parts[2] * 1024) : nil
        }
        let total = Int64((Int(env["UTERM_BENCH_TOTAL_MIB"] ?? "") ?? 512) * 1_048_576)
        let segment = (Int(env["UTERM_BENCH_SEGMENT_MIB"] ?? "") ?? 8) * 1_048_576
        let direction = env["UTERM_BENCH_DIRECTION"] ?? "down"

        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        limit.rlim_cur = min(limit.rlim_max, 10_240)
        setrlimit(RLIMIT_NOFILE, &limit)

        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let spec = HostConnectionSpec(
            id: UUID(), name: "bench",
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: "root", password: env["UTERM_BENCH_PASSWORD"] ?? "PASS"),
            jumpAuth: nil, container: container)

        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "engine-\(UUID().uuidString.prefix(6)).bin")
        defer { try? FileManager.default.removeItem(at: local) }
        var verified = false

        for (channels, inFlight, window) in configs {
            let tuning = ParallelTransfer.Tuning(
                channels: channels, inFlight: inFlight, windowBytes: window, segmentBytes: segment)
            let pool = ControlConnectionPool(
                connector: .live(transferWindowBytes: window), maxSFTPChannels: channels)
            try await Self.trustIfNeeded(pool: pool, spec: spec)

            if direction != "up" {
                let fd = open(local.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
                XCTAssertGreaterThanOrEqual(fd, 0)
                let meter = FootprintMeter()
                let started = Date()
                _ = try await ParallelTransfer.download(
                    host: spec, pool: pool, remotePath: "/root/big", fd: fd,
                    ranges: [.init(offset: 0, length: total)], tuning: tuning, onSegment: { _ in })
                let seconds = Date().timeIntervalSince(started)
                meter.stop()
                close(fd)
                report("down", tuning, total, seconds, meter.peakMiB)
                if !verified {
                    try await Self.verifyDownload(pool: pool, spec: spec, local: local, total: total)
                    verified = true
                }
            }
            if direction != "down" {
                if (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) != total {
                    try Data(count: Int(total)).write(to: local)
                }
                let fd = open(local.path, O_RDONLY)
                let meter = FootprintMeter()
                let started = Date()
                _ = try await ParallelTransfer.upload(
                    host: spec, pool: pool, fd: fd, remotePath: "/root/up.bin", mode: .overwrite,
                    ranges: nil, tuning: tuning, onSegment: { _ in })
                let seconds = Date().timeIntervalSince(started)
                meter.stop()
                close(fd)
                report("up", tuning, total, seconds, meter.peakMiB)
            }
            await pool.disconnectAll()
        }
        print("ENGINE done")
    }

    private func report(_ direction: String, _ tuning: ParallelTransfer.Tuning, _ bytes: Int64,
                        _ seconds: Double, _ peak: Double) {
        print(String(format: "ENGINE|%@|通道 %3d|在途 %4d|窗口 %6d KiB|段 %3d MiB|%7.1f MiB/s|%6.2f s|内存增量 %5.0f MiB",
                     direction, tuning.channels, tuning.inFlight, tuning.windowBytes / 1024,
                     tuning.segmentBytes / 1_048_576, Double(bytes) / 1_048_576 / seconds, seconds, peak))
    }

    /// 首连主机密钥未知：按挑战里的指纹 trust 一次（内存库）。
    private static func trustIfNeeded(pool: ControlConnectionPool, spec: HostConnectionSpec) async throws {
        do {
            let session = try await pool.borrowSFTP(for: spec)
            await pool.returnSFTP(session, for: spec.id)
        } catch let error as ControlConnectError {
            guard let fingerprint = error.fingerprint else { throw error }
            try await pool.trustHostKey(host: spec, fingerprint: fingerprint)
        }
    }

    private static func verifyDownload(pool: ControlConnectionPool, spec: HostConnectionSpec,
                                local: URL, total: Int64) async throws {
        let executor = try await pool.executor(for: spec)
        let remote = try await executor.run("head -c \(total) /root/big | sha256sum")
        let expected = String(remote.output.prefix(64))
        let handle = try FileHandle(forReadingFrom: local)
        var hasher = SHA256()
        var left = Int(total)   // 本地文件被截成了远端全长，只比前 total 字节
        while left > 0, let data = try handle.read(upToCount: min(8 << 20, left)), !data.isEmpty {
            hasher.update(data: data)
            left -= data.count
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, expected, "引擎写出来的字节和远端不一致")
        print("ENGINE verify \(actual == expected ? "ok" : "MISMATCH") \(actual.prefix(16))")
    }

    /// 采样本进程的 `phys_footprint` 峰值。
    private nonisolated final class FootprintMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Double = 0
        private var base: Double?
        private var running = true

        init() {
            Thread { [self] in
                while lock.withLock({ running }) {
                    var info = task_vm_info_data_t()
                    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                    let kr = withUnsafeMutablePointer(to: &info) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                        }
                    }
                    if kr == KERN_SUCCESS {
                        let value = Double(info.phys_footprint) / 1_048_576
                        lock.withLock {
                            if base == nil { base = value }
                            peak = max(peak, value - (base ?? value))
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }.start()
        }

        func stop() { lock.withLock { running = false } }
        var peakMiB: Double { lock.withLock { peak } }
    }
}

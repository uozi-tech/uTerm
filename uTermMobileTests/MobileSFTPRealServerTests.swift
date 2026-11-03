import CryptoKit
import SwiftData
import XCTest
@testable import uTermMobile

/// SFTP 真服务器集成用例：产品的 `MobileSFTPController` 连一台真实 sshd，走流式上传 / 下载、
/// 目录排序，并量传输期间主线程的最长停顿。
///
/// 默认跳过——需要一台可用的测试服务器，经环境变量给出（xcodebuild 会把 `TEST_RUNNER_` 前缀
/// 去掉后传给测试进程）：
///
///     TEST_RUNNER_UTERM_SFTP_HOST=127.0.0.1 TEST_RUNNER_UTERM_SFTP_PORT=2222 \
///     TEST_RUNNER_UTERM_SFTP_USER=root TEST_RUNNER_UTERM_SFTP_PASSWORD=… xcodebuild test …
///
/// 只用测试服务器；钥匙串条目用新造的 id，用例结束即删。
@MainActor
final class MobileSFTPRealServerTests: XCTestCase {

    func testStreamingUploadDownloadAndSortAgainstRealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["UTERM_SFTP_HOST"], let password = env["UTERM_SFTP_PASSWORD"] else {
            throw XCTSkip("未配置 UTERM_SFTP_HOST / UTERM_SFTP_PASSWORD，跳过真服务器用例")
        }
        let container = try MobileFixtures.emptyContainer()
        let profile = ServerProfile()
        profile.name = "sftp-it"
        profile.host = host
        profile.port = Int(env["UTERM_SFTP_PORT"] ?? "22") ?? 22
        profile.username = env["UTERM_SFTP_USER"] ?? "root"
        profile.authMethod = .password
        container.mainContext.insert(profile)
        try container.mainContext.save()
        let keychain = KeychainStore()
        try keychain.save(password, profileID: profile.id, kind: .password)
        defer { try? keychain.delete(profileID: profile.id, kind: .password) }

        // 建连：首连的 host-key 挑战自动信任（只对测试服务器）。
        let relay = HostKeyChallengeRelay()
        let controller = MobileSFTPController()
        controller.start(profile: profile, container: container, relay: relay)
        let connected = await waitUntil(timeout: 30) {
            if relay.pendingChallenge != nil { relay.resolve(true) }
            return controller.state == .connected && !controller.loading
        }
        XCTAssertTrue(connected, "没连上：\(controller.state)")
        defer { controller.close() }
        let home = controller.path

        // 流式上传一个 24MB 文件，期间每 5ms 在主线程打一拍，记最长间隔。
        let payload = Data((0..<(24 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        let name = "uterm-it-\(UUID().uuidString.prefix(8)).bin"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()
        let uploadStart = Date()
        controller.upload(from: local)
        let uploaded = await waitUntil(timeout: 120) {
            controller.entries.contains { $0.name == name && $0.size == UInt64(payload.count) }
        }
        let uploadSeconds = Date().timeIntervalSince(uploadStart)
        XCTAssertTrue(uploaded, "上传后列表里没有完整大小的文件：\(controller.state)")
        XCTAssertEqual(controller.path, home)

        let entry = try XCTUnwrap(controller.entries.first { $0.name == name })
        let downloadStart = Date()
        let downloadedURL = await controller.download(entry, in: home)
        let downloadSeconds = Date().timeIntervalSince(downloadStart)
        heartbeat.stop()
        let downloaded = try XCTUnwrap(downloadedURL, "下载失败：\(controller.state)")
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: downloaded)),
                       SHA256.hash(data: payload), "上传下载往返字节不一致")
        print(String(format: "[sftp-it] 24MB upload=%.2fs download=%.2fs main-thread max gap=%.1fms",
                     uploadSeconds, downloadSeconds, heartbeat.maxGapMS))
        // 改前上传在主线程同步读整个文件、下载在主线程写整个文件；改后不该有百毫秒级的停顿。
        XCTAssertLessThan(heartbeat.maxGapMS, 250, "传输期间主线程被长时间阻塞")

        // 排序：目录在前，同类按名字本地化大小写无关升序。
        let entries = controller.entries
        let expected = entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        XCTAssertEqual(entries.map(\.name), expected.map(\.name))

        // 清理远端文件，并确认列表刷新。
        controller.delete(entry, in: home)
        let removed = await waitUntil(timeout: 30) { !controller.entries.contains { $0.name == name } }
        XCTAssertTrue(removed)
    }

    private func waitUntil(timeout seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// 主线程心跳：每 5ms 记一次，最长间隔就是这段时间里主线程最久一次没空出来。
@MainActor
private final class MainThreadHeartbeat {
    private var task: Task<Void, Never>?
    private(set) var maxGapMS: Double = 0

    func start() {
        task = Task { @MainActor [weak self] in
            var last = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = CFAbsoluteTimeGetCurrent()
                if let self { self.maxGapMS = max(self.maxGapMS, (now - last) * 1000) }
                last = now
            }
        }
    }

    func stop() { task?.cancel() }
}

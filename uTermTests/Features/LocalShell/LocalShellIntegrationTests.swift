import XCTest
@testable import uTerm

/// 本机 shell 的真实链路：测试宿主就是沙盒的 uTerm.app，`NSXPCConnection(serviceName:)` 找的正是它包里
/// `Contents/XPCServices/uTermShellAgent.xpc`。验证三件事：沙盒 app 能拉起不带沙盒的内嵌服务；起出来的是
/// 用户的登录 shell，读得到主目录（在沙盒里读不到）；调尺寸、结束都生效。会真的起一个你的登录 shell。
@MainActor
final class LocalShellIntegrationTests: XCTestCase {

    /// 进程是否还在（僵尸不算）。不能用 `kill(pid, 0)`：测试宿主在沙盒里，对沙盒外的 shell 恒返回 EPERM。
    private static func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    func test_sandboxed_host_opens_unsandboxed_login_shell_through_embedded_xpc_service() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let version = try await client.ping()
        XCTAssertFalse(version.isEmpty)

        let sessionID = UUID()
        let backend = LocalShellBackend(client: client, namespace: "integration-test", sessionID: sessionID,
                                        columns: 80, rows: 24)
        try await backend.connect()
        var output = ""
        let pump = Task { @MainActor in
            for await case .bytes(let chunk) in backend.outputItems { output += String(decoding: chunk, as: UTF8.self) }
        }
        defer { pump.cancel() }

        func waitFor(_ needle: String, timeout: TimeInterval = 15) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !output.contains(needle) {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        // 主目录真能读：沙盒里的进程读不了 ~/Library 的列表，不带沙盒的登录 shell 可以。
        await backend.write(Data("ls ~/Library >/dev/null 2>&1 && echo HOME_OK_$((40+2)) || echo HOME_DENIED_$((40+2))\n".utf8))
        let listed = await waitFor("_42")
        XCTAssertTrue(listed, "shell 没有回应：\(output.suffix(400))")
        XCTAssertTrue(output.contains("HOME_OK_42"), "shell 读不到主目录（还在沙盒里？）：\(output.suffix(400))")

        // 终端的编号写进了环境变量：终端里跑的 `utermctl` 凭它告诉 uTerm 自己在哪个终端里。
        await backend.write(Data("echo SESSION_${UTERM_SESSION_ID}_END\n".utf8))
        let identified = await waitFor("SESSION_\(sessionID.uuidString)_END")
        XCTAssertTrue(identified, "shell 里没有 UTERM_SESSION_ID：\(output.suffix(300))")

        await backend.resize(cols: 99, rows: 33)
        try? await Task.sleep(for: .milliseconds(200))
        await backend.write(Data("stty size\n".utf8))
        let resized = await waitFor("33 99")
        XCTAssertTrue(resized, "调尺寸没生效：\(output.suffix(200))")

        guard let pid = await backend.pid else { return XCTFail("没有进程号") }
        await backend.close()
        let deadline = Date().addingTimeInterval(5)
        while Self.isAlive(pid), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(Self.isAlive(pid), "结束后 shell 进程还在")
    }

    /// 起在指定目录；目录没了还是要起来，落在主目录；之后 `cd` 问得到。
    func test_shell_starts_in_the_requested_directory_and_reports_where_it_went() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }

        func waitForDirectory(_ backend: LocalShellBackend, _ expected: String) async -> String? {
            let deadline = Date().addingTimeInterval(15)
            var current = await backend.workingDirectory()
            while current != expected, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                current = await backend.workingDirectory()
            }
            return current
        }

        let backend = LocalShellBackend(client: client, namespace: "integration-test", directory: "/usr/bin", columns: 80, rows: 24)
        try await backend.connect()
        let drain = Task { for await _ in backend.outputItems {} }
        defer { drain.cancel() }
        let started = await waitForDirectory(backend, "/usr/bin")
        XCTAssertEqual(started, "/usr/bin")

        await backend.write(Data("cd /usr/lib\n".utf8))
        let moved = await waitForDirectory(backend, "/usr/lib")
        XCTAssertEqual(moved, "/usr/lib")
        await backend.close()

        let missing = LocalShellBackend(client: client, namespace: "integration-test", directory: "/no/such/directory",
                                        columns: 80, rows: 24)
        try await missing.connect()
        let drainMissing = Task { for await _ in missing.outputItems {} }
        defer { drainMissing.cancel() }
        let fallback = await waitForDirectory(missing, LocalShellWorkspaces.home)
        XCTAssertEqual(fallback, LocalShellWorkspaces.home)
        await missing.close()
    }

    /// shell 自己退出（用户敲 exit）：后端要报告会话结束，否则界面和手机上画面一直冻着。
    func test_natural_shell_exit_is_reported_on_exit_stream() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let sessionID = UUID()
        let backend = LocalShellBackend(client: client, namespace: "integration-test", sessionID: sessionID,
                                        columns: 80, rows: 24)
        try await backend.connect()
        let drain = Task { for await _ in backend.outputItems {} }
        defer { drain.cancel() }
        let exited = Task { () -> Bool in
            for await _ in backend.exitStream { return true }
            return false
        }
        await backend.write(Data("exit\n".utf8))
        let reported = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await exited.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                exited.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(reported, "shell 退出后 exitStream 应产出一个元素")
    }

    /// 关本机标签要真的结束 shell，不能等到 uTerm 退出才收尸。
    func test_disposing_pane_terminates_its_shell() async throws {
        let pane = LocalShellPane()
        await pane.start()
        guard let backend = pane.session.backend as? LocalShellBackend, let pid = await backend.pid else {
            return XCTFail("shell 没起来：\(pane.session.connectionState)")
        }
        XCTAssertTrue(Self.isAlive(pid))
        pane.dispose()
        let deadline = Date().addingTimeInterval(8)
        while Self.isAlive(pid), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(Self.isAlive(pid), "关标签后 shell 进程还在")
    }

    /// ⌘ 点相对路径 / `~/` 时问本机 shell 的目录：当前目录是 shell 的（不是测试宿主的），家目录是真的主目录（不是沙盒容器）。
    /// 不存在的路径辅助程序回 false、不打开任何东西。
    func test_local_shell_reports_foreground_directories_and_refuses_missing_paths() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let backend = LocalShellBackend(client: client, namespace: "integration-test", sessionID: UUID(), directory: "/usr",
                                        columns: 80, rows: 24)
        try await backend.connect()
        defer { Task { await backend.close() } }

        var dirs: RemoteForegroundDirectories?
        for _ in 0..<100 {
            dirs = await backend.foregroundDirectories()
            if dirs?.workingDirectory != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(dirs?.workingDirectory, "/usr")
        let home = try XCTUnwrap(dirs?.home)
        XCTAssertFalse(home.contains("/Library/Containers/"), "家目录不能是沙盒容器：\(home)")
        XCTAssertTrue(home.hasPrefix("/"))

        let missing = await backend.openLocalPath("/nonexistent-uterm-\(UUID().uuidString)/plan.md")
        XCTAssertFalse(missing)
    }
}

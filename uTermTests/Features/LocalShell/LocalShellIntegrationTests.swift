import XCTest
@testable import uTerm

/// 本机 shell 的真实链路：测试宿主就是沙盒的 uTerm.app，`NSXPCConnection(serviceName:)` 找的正是它包里
/// `Contents/XPCServices/uTermShellAgent.xpc`。验证三件事：沙盒 app 能拉起不带沙盒的内嵌服务；起出来的是
/// 用户的登录 shell，读得到主目录（在沙盒里读不到）；调尺寸、结束都生效。会真的起一个你的登录 shell。
@MainActor
final class LocalShellIntegrationTests: XCTestCase {

    func test_sandboxed_host_opens_unsandboxed_login_shell_through_embedded_xpc_service() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let version = try await client.ping()
        XCTAssertFalse(version.isEmpty)

        let backend = LocalShellBackend(client: client, columns: 80, rows: 24)
        try await backend.connect()
        var output = ""
        let pump = Task { @MainActor in
            for await chunk in backend.outputStream { output += String(decoding: chunk, as: UTF8.self) }
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

        await backend.resize(cols: 99, rows: 33)
        try? await Task.sleep(for: .milliseconds(200))
        await backend.write(Data("stty size\n".utf8))
        let resized = await waitFor("33 99")
        XCTAssertTrue(resized, "调尺寸没生效：\(output.suffix(200))")

        guard let pid = await backend.pid else { return XCTFail("没有进程号") }
        await backend.close()
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, "结束后 shell 进程还在")
    }
}

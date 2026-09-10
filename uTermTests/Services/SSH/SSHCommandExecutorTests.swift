import XCTest
@testable import uTerm
@testable import USSHKit

final class SSHCommandExecutorTests: XCTestCase {
    func testWrapsCommandAndParsesExitCode() async throws {
        let captured = LockBox<String>("")
        let exec = SSHCommandExecutor { cmd in
            captured.set(cmd)
            return "hello\n__UTERM_EXIT__:0\n"
        }
        let r = try await exec.run("echo hello")
        XCTAssertTrue(captured.get().contains("echo hello"))
        XCTAssertEqual(r.output, "hello")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testNonZeroExitCodePreservesOutput() async throws {
        let exec = SSHCommandExecutor { _ in "boom\n__UTERM_EXIT__:2\n" }
        let r = try await exec.run("false")
        XCTAssertEqual(r.output, "boom")
        XCTAssertEqual(r.exitCode, 2)
    }

    func testOutputCapTruncates() async throws {
        let big = String(repeating: "x\n", count: 5000)
        let exec = SSHCommandExecutor(maxLines: 200) { _ in big + "__UTERM_EXIT__:0\n" }
        let r = try await exec.run("yes")
        XCTAssertTrue(r.output.contains("[输出已截断]"))
        XCTAssertLessThanOrEqual(r.output.split(separator: "\n").count, 202)
        // 截断与否由执行器直接带出，调用方不必再去嗅探末尾文案。
        XCTAssertTrue(r.truncated)
    }

    /// 顶层 `exit N` 必须仍带得回退出码。
    ///
    /// 回归：包装用命令组 `{ …; }` 时，`exit 3` 在**当前** shell 里执行，直接退掉
    /// 整个 shell —— 哨兵没机会打印，Citadel 对非零退出抛错，CLI 那头看到的是
    /// 「connect_failed：操作未能完成，请稍后重试」，3 ms 就返回。子 shell `( … )`
    /// 里 `exit 3` 只退子 shell，`$?` 照样是 3。
    func testTopLevelExitIsWrappedInASubshell() async throws {
        let captured = LockBox<String>("")
        let exec = SSHCommandExecutor { cmd in
            captured.set(cmd)
            // 远端只回哨兵：`exit 3` 自己不产出任何输出。
            return "\n__UTERM_EXIT__:3\n"
        }
        let r = try await exec.run("exit 3")

        let wrapped = captured.get()
        XCTAssertTrue(wrapped.hasPrefix("( exit 3\n)"),
                      "必须包成子 shell，实得：\(wrapped)")
        XCTAssertFalse(wrapped.hasPrefix("{"), "命令组会让顶层 exit 退掉整个 shell")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.output, "")
        XCTAssertFalse(r.truncated)
    }

    /// 命令以行注释结尾时，`)` 不能被一起注释掉 —— 所以用换行而不是 `;` 收口。
    func testTrailingCommentDoesNotSwallowTheClosingParen() async throws {
        let captured = LockBox<String>("")
        let exec = SSHCommandExecutor { cmd in
            captured.set(cmd)
            return "hi\n__UTERM_EXIT__:0\n"
        }
        _ = try await exec.run("echo hi # 注释")
        XCTAssertTrue(captured.get().contains("# 注释\n)"), captured.get())
    }

    func testUntruncatedOutputIsNotFlagged() async throws {
        let exec = SSHCommandExecutor(maxLines: 200) { _ in "hi\n__UTERM_EXIT__:0\n" }
        let r = try await exec.run("echo hi")
        XCTAssertFalse(r.truncated)
    }
}

/// 小工具：测试里捕获闭包写入的值（闭包是 @Sendable）。
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

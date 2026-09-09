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

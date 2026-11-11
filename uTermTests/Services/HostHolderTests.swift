import Foundation
import XCTest
@testable import uTerm

/// 主机上的会话保持进程在 App 这头的常量、命令和打包的二进制（全离线）。
final class HostHolderTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - 和 Go 那头对得上

    /// 文件名里带版本，App 认的版本和 Go 编出来的不一样的话，装上去的二进制永远对不上号。
    func testVersionMatchesTheGoSource() throws {
        let main = try source("holder/cmd/uterm-holder/main.go")
        let line = try XCTUnwrap(main.split(separator: "\n").first { $0.hasPrefix("const version = ") })
        XCTAssertEqual(String(line), "const version = \"\(HostHolder.version)\"")
    }

    func testProtocolVersionAndExitCodesMatchTheGoSource() throws {
        let wire = try source("holder/internal/holder/wire.go")
        XCTAssertTrue(wire.contains("ProtocolVersion uint32 = \(HostHolder.protocolVersion)"))
        let main = try source("holder/cmd/uterm-holder/main.go")
        XCTAssertTrue(main.contains("exitNoSession = \(HostHolder.ExitCode.noSession)"))
    }

    /// attach 帧的负载两头各写了一份，字节要一样（Go 那头的布局见 wire_test.go 的 TestAttachOffsetPayload）。
    func testAttachPayloadLayout() {
        XCTAssertEqual(HostHolderAttach.fromStoredCheckpoint, [])
        XCTAssertEqual(HostHolderAttach.fromOffset(0x0102030405060708), [1, 8, 7, 6, 5, 4, 3, 2, 1])
    }

    // MARK: - 命令

    func testAttachCommandCreatesWithSizeEnvironmentAndTimeout() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let command = HostHolder.attachCommand(
            sessionID: id, create: true, cols: 120, rows: 40,
            environment: [("LANG", "en_US.UTF-8"), ("BAD", "a b"), ("QUOTE", "it's"), ("COLORTERM", "truecolor")])
        // 外面包一层 sh -c '…'：登录 shell 可能是 fish / csh。里面不能再有单引号。
        XCTAssertTrue(command.hasPrefix("sh -c '"), command)
        XCTAssertTrue(command.hasSuffix("'"), command)
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2, command)
        XCTAssertTrue(command.contains(
            "attach --id 11111111-2222-3333-4444-555555555555 --create --cols 120 --rows 40 --term xterm-256color"
                + " --detached-timeout 86400s --env LANG=en_US.UTF-8 --env COLORTERM=truecolor;"), command)
        // 放进命令行会出事的值不带。
        XCTAssertFalse(command.contains("BAD"), command)
        XCTAssertFalse(command.contains("QUOTE"), command)
        XCTAssertTrue(command.contains("uterm-holder-\(HostHolder.version)"), command)
        XCTAssertTrue(command.contains("exit \(HostHolder.ExitCode.unsupported)"), command)
        XCTAssertTrue(command.hasSuffix("exit \(HostHolder.ExitCode.notInstalled)'"), command)
    }

    func testReattachCommandDoesNotCreate() {
        let command = HostHolder.attachCommand(sessionID: UUID(), create: false, cols: 80, rows: 24, environment: [])
        XCTAssertFalse(command.contains("--create"), command)
        XCTAssertFalse(command.contains("--cols"), command)
    }

    func testInstallCommandReadsExactlyTheBinaryAndProbes() {
        let command = HostHolder.installCommand(byteCount: 3_342_460)
        XCTAssertTrue(command.contains("head -c 3342460 > \"$p.tmp\""), command)
        XCTAssertTrue(command.hasSuffix("\"$p\" probe'"), command)
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2, command)
    }

    func testUnsupportedMarkerKeepsTheScriptWellFormed() {
        let command = HostHolder.markUnsupportedCommand(reason: "it's \"bad\"; rm -rf / $(x) `y`")
        XCTAssertEqual(command.filter { $0 == "'" }.count, 2, command)
        XCTAssertTrue(command.contains("echo \"its bad rm -rf  x y\" > \"$p.unsupported\""), command)
    }

    // MARK: - 主机信息

    func testResourceNameForUname() {
        XCTAssertEqual(HostHolder.resourceName(forUname: "Linux x86_64\n"), "uterm-holder-linux-amd64")
        XCTAssertEqual(HostHolder.resourceName(forUname: "Linux aarch64"), "uterm-holder-linux-arm64")
        XCTAssertEqual(HostHolder.resourceName(forUname: "Linux arm64"), "uterm-holder-linux-arm64")
        XCTAssertNil(HostHolder.resourceName(forUname: "Darwin arm64"))
        XCTAssertNil(HostHolder.resourceName(forUname: "Linux armv7l"))
        XCTAssertNil(HostHolder.resourceName(forUname: "Linux"))
        XCTAssertNil(HostHolder.resourceName(forUname: ""))
    }

    func testProbeReportParsingAndUsability() throws {
        let noisy = "Welcome to the box\n{\"version\":\"\(HostHolder.version)\",\"protocol\":1,\"survivesLogout\":\"yes\",\"linger\":false}\n"
        let report = try XCTUnwrap(HostHolder.parseProbe(noisy))
        XCTAssertTrue(report.isUsable)

        var unknown = report
        unknown.survivesLogout = "unknown"
        XCTAssertTrue(unknown.isUsable)

        // 退出登录时主机会清进程：会话留不下来，不用它。
        var killed = report
        killed.survivesLogout = "no"
        XCTAssertFalse(killed.isUsable)

        var older = report
        older.version = "0.0.1"
        XCTAssertFalse(older.isUsable)

        XCTAssertNil(HostHolder.parseProbe("command not found\n"))
        XCTAssertNil(HostHolder.parseProbe("{not json}\n"))
    }

    // MARK: - 打包的二进制

    /// 两个架构都打进了 App 包（`make holder`），解出来是对应架构的 Linux 可执行文件。
    func testBundledBinariesAreLinuxExecutablesOfTheRightArchitecture() throws {
        // ELF 头：e_ident[4] 位宽、[5] 字节序，e_machine 在偏移 18（小端）。
        let expectedMachine: [String: UInt16] = ["uterm-holder-linux-amd64": 0x3E, "uterm-holder-linux-arm64": 0xB7]
        for (name, machine) in expectedMachine {
            let binary = try XCTUnwrap(HostHolder.bundledBinary(named: name),
                                       "\(name) 没打进 App 包：先跑 make holder")
            XCTAssertGreaterThan(binary.count, 1_000_000, name)
            XCTAssertEqual(Array(binary.prefix(4)), [0x7F, 0x45, 0x4C, 0x46], name)
            XCTAssertEqual(binary[4], 2, "\(name) 应当是 64 位")
            XCTAssertEqual(binary[5], 1, "\(name) 应当是小端")
            XCTAssertEqual(UInt16(binary[18]) | UInt16(binary[19]) << 8, machine, name)
            // 是我们的那个程序（用法提示编在二进制里）。
            XCTAssertNotNil(binary.range(of: Data("usage: uterm-holder attach".utf8)), name)
        }
        XCTAssertNil(HostHolder.bundledBinary(named: "uterm-holder-linux-riscv64"))
    }
}

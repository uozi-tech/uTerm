import Foundation
import XCTest
@testable import uTerm

/// 主机上正在运行的 Claude Code（`~/.claude/sessions/<pid>.json`）：命令怎么拼、输出怎么解析。
/// 用户报的：侧栏的「在跑」只认本设备 Code 标签页里开的，在别处开的、还没报状态的都显示成没在跑。
final class ClaudeLiveSessionsTests: XCTestCase {
    private static let begin = ClaudeLiveSessions.beginMarker
    private static let end = ClaudeLiveSessions.endMarker + " 0"

    private func json(_ pid: Int, _ id: String, status: String?, procStart: String? = "Thu Nov 26 13:07:37 2026",
                      cwd: String = "/Users/a/proj") -> String {
        var object: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "kind": "interactive", "entrypoint": "cli",
                                     "startedAt": 1_795_698_458_761, "updatedAt": 1_795_698_468_237]
        if let status { object["status"] = status }
        if let procStart { object["procStart"] = procStart }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func entry(_ pid: Int, start: String = "Thu Nov 26 13:07:37 2026    ", _ body: String) -> String {
        "\(ClaudeLiveSessions.pidMarker) \(pid) \(start)\n\(body)\n"
    }

    // MARK: 解析

    func testParsesLiveSessionsAndMapsStatuses() throws {
        let output = "登录脚本打印的东西\n\(Self.begin)\n"
            + entry(30511, json(30511, "0944DA93-5089-43e6-9797-1a5ae564fd41", status: "busy"))
            + entry(98292, json(98292, "fcbda69f-749c-4506-acfd-67cbe8222c44", status: "idle"))
            + entry(98902, json(98902, "65dee7fb-110f-4505-985c-d4754583a0d7", status: "shell"))
            + entry(4, json(4, "aaaaaaaa-0000-0000-0000-000000000004", status: "waiting_for_permission"))
            + entry(5, json(5, "aaaaaaaa-0000-0000-0000-000000000005", status: nil))
            + "\(Self.end)\n"
        let sessions = try ClaudeLiveSessions.parse(output)
        let states = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0.state) })
        XCTAssertEqual(states, [30511: .working, 98292: .idle, 98902: .unknown, 4: .waiting, 5: .unknown],
                       "busy = 运行中，idle = 空闲，带 wait/permission/input 字样的 = 等人，其余（shell、没报）= 没报")
        XCTAssertTrue(sessions.allSatisfy { $0.tool == .claude && $0.directory == "/Users/a/proj" })
        XCTAssertEqual(sessions.first { $0.pid == 30511 }?.key.sessionID, "0944da93-5089-43e6-9797-1a5ae564fd41",
                       "会话 ID 不论大小写")
    }

    func testStatusWordsThatLookLikeWaiting() {
        for status in ["waiting", "Permission", "needs_input", "awaiting_input"] {
            XCTAssertEqual(ClaudeLiveSessions.state(of: status), .waiting, status)
        }
        for status in ["shell", "compacting", "", "BUSYISH"] {
            XCTAssertEqual(ClaudeLiveSessions.state(of: status), .unknown, status)
        }
        XCTAssertEqual(ClaudeLiveSessions.state(of: "BUSY"), .working)
        XCTAssertEqual(ClaudeLiveSessions.state(of: nil), .unknown)
    }

    func testSkipsBadJSONMismatchedPIDAndReusedProcessIDs() throws {
        let output = "\(Self.begin)\n"
            + entry(11, "{\"pid\":11,\"sessionId\":\"broken")                          // 写到一半 / 被截断
            + entry(12, json(99, "aaaaaaaa-0000-0000-0000-000000000012", status: "busy")) // 里面写的不是这个进程
            + entry(13, json(13, "", status: "busy"))                                   // 没有会话 ID
            // 进程号被别的进程用上了（重启之后）：ps 报的启动时间和文件里记的对不上。
            + entry(14, start: "Fri Nov 27 02:11:08 2026", json(14, "aaaaaaaa-0000-0000-0000-000000000014", status: "busy"))
            // 时区写法不同（差整小时）：算同一个进程。
            + entry(15, start: "Thu Nov 26 21:07:37 2026", json(15, "aaaaaaaa-0000-0000-0000-000000000015", status: "busy"))
            // ps 不支持 lstart（busybox）、文件里没写 procStart：只靠 kill -0。
            + entry(16, start: "", json(16, "aaaaaaaa-0000-0000-0000-000000000016", status: "idle"))
            + entry(17, json(17, "aaaaaaaa-0000-0000-0000-000000000017", status: "idle", procStart: nil))
            // 一位数的日子 ps 补空格。
            + entry(18, start: "Fri Nov  6 13:07:37 2026", json(18, "aaaaaaaa-0000-0000-0000-000000000018", status: "idle",
                                                                 procStart: "Fri Nov 6 13:07:38 2026"))
            + "\(Self.end)\n"
        XCTAssertEqual(try ClaudeLiveSessions.parse(output).map(\.pid).sorted(), [15, 16, 17, 18])
    }

    func testSameSessionTwiceKeepsTheMoreUrgent() throws {
        let id = "aaaaaaaa-0000-0000-0000-000000000001"
        let output = "\(Self.begin)\n" + entry(1, json(1, id, status: "idle")) + entry(2, json(2, id, status: "busy"))
            + entry(3, json(3, id.uppercased(), status: "idle")) + "\(Self.end)\n"
        let sessions = try ClaudeLiveSessions.parse(output)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .working)
    }

    func testMissingDirectoryMeansNothingRunning() throws {
        XCTAssertEqual(try ClaudeLiveSessions.parse("\(Self.begin)\n\(ClaudeLiveSessions.endMarker) 200\n"), [])
        XCTAssertEqual(try ClaudeLiveSessions.parse("\(Self.begin)\n\(Self.end)"), [])
    }

    func testIncompleteOrMissingOutputThrows() {
        XCTAssertThrowsError(try ClaudeLiveSessions.parse("command not found: sh")) {
            XCTAssertEqual($0 as? ClaudeLiveSessions.ReadError, .cannotExecute)
        }
        XCTAssertThrowsError(try ClaudeLiveSessions.parse("\(Self.begin)\n" + entry(1, json(1, "a", status: "busy")))) {
            XCTAssertEqual($0 as? ClaudeLiveSessions.ReadError, .incompleteOutput, "没有结束标记：不当成「没有在跑的」")
        }
    }

    // MARK: 命令

    /// 命令的形状同搜索：`sh -c '…' sh '<脚本>' '<目录>'`，脚本和目录都编码过，单引号里没有 `!`、换行、`$`，
    /// csh / fish 也原样交给 sh。
    func testCommandIsEncodedForAnyLoginShell() {
        let command = ClaudeLiveSessions.command(sessionsDirectory: "/home/张 三/it's/.claude/sessions")
        XCTAssertTrue(command.hasPrefix(#"sh -c 'eval "$(printf %b "$1")"' sh '"#))
        let tail = command.dropFirst(#"sh -c 'eval "$(printf %b "$1")"' sh "#.count)
        XCTAssertFalse(tail.contains("!"))
        XCTAssertFalse(tail.contains("\n"))
        XCTAssertFalse(tail.contains("$"))
        XCTAssertEqual(tail.filter { $0 == "'" }.count, 4, "两个参数，各一对单引号")
        XCTAssertEqual(ClaudeLiveSessions.directory(home: "/home/a/"), "/home/a/.claude/sessions")
    }

    /// 真跑一遍（sh 与 csh 当登录 shell）：活着的进程（这个测试进程自己）那份回来，进程已经退出的、`.key`、名字不是数字的不回来。
    func testCommandRunsUnderShAndCsh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-live-\(UUID().uuidString)/has space!/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }

        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let dead = try exitedProcessID()
        let start = run("/bin/sh", ["-c", "LC_ALL=C TZ=UTC0 ps -o lstart= -p \(me)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try json(me, "11111111-1111-1111-1111-111111111111", status: "busy", procStart: start.isEmpty ? nil : start)
            .write(to: directory.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        try json(dead, "22222222-2222-2222-2222-222222222222", status: "busy")
            .write(to: directory.appendingPathComponent("\(dead).json"), atomically: true, encoding: .utf8)
        try "secret".write(to: directory.appendingPathComponent("\(me).abcdef.key"), atomically: true, encoding: .utf8)
        try json(me, "33333333-3333-3333-3333-333333333333", status: "busy")
            .write(to: directory.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)

        let command = ClaudeLiveSessions.command(sessionsDirectory: directory.path)
        for shell in ["/bin/sh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let sessions = try ClaudeLiveSessions.parse(run(shell, ["-c", command]))
            XCTAssertEqual(sessions.map(\.sessionID), ["11111111-1111-1111-1111-111111111111"], shell)
            XCTAssertEqual(sessions.first?.state, .working, shell)
        }
        let missing = ClaudeLiveSessions.command(sessionsDirectory: directory.path + "/nope")
        XCTAssertEqual(try ClaudeLiveSessions.parse(run("/bin/sh", ["-c", missing])), [], "目录不存在：没有在跑的")
    }

    private func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// 一个已经退出的进程的进程号。
    private func exitedProcessID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }
}

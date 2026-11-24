import XCTest
@testable import uTerm

/// 拼给远端 shell 的命令里，名字永远只是参数：不管名字里有什么（`"$a0"`、引号、`;`、`$(…)`），都不能变成命令文字。
///
/// 回归：直接写的那条路曾经按下标逐个 `replacingOccurrences`，后面那个参数里的 `"$a0"` 会在已经换进去的单引号串里
/// 再被换一次，把前一个名字放到引号外面执行——只要打开一个放了两个特制文件名的目录（属主 stat）就在服务器上跑了命令。
final class RemoteShellInjectionTests: XCTestCase {

    private func run(_ command: String, in directory: URL) throws -> (status: Int32, output: [UInt8]) {
        // 命令从标准输入交给 sh（`sh -s`），不放进 `Process.arguments`：Foundation 会把参数按文件系统的写法转成 NFD，
        // `é` 到了 sh 那里就变成 `e` + 组合符，测的就不是逐字节了。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.currentDirectoryURL = directory
        let input = Pipe()
        let pipe = Pipe()
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, Array(data))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 每个参数一行（NUL 分隔），原样回显：`printf '%s\0' "$a0" "$a1" …`。
    private func echoCommand(_ arguments: [String], escaped: Bool = false) -> String {
        RemotePath.shScript("printf '%s\\0' \(arguments: 0..<arguments.count)", arguments: arguments, escapedNames: escaped)
    }

    private func split(_ output: [UInt8]) -> [[UInt8]] {
        var parts = output.split(separator: 0, omittingEmptySubsequences: false).map(Array.init)
        if parts.last == [] { parts.removeLast() }
        return parts
    }

    func testAPlaceholderInsideOneArgumentIsNeverExpandedIntoAnother() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pwned")
        let names = ["/d/; touch \(marker.path); ", "/d/z\"$a0\"z"]

        let command = echoCommand(names)
        XCTAssertFalse(command.contains("'/d/z'/d/"), "第二个参数的引号被拆开了：\(command)")

        let result = try run(command, in: directory)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "名字被当成命令执行了：\(command)")
        XCTAssertEqual(split(result.output), names.map { Array($0.utf8) })
    }

    /// 走 `sh -c` 那条路（名字里有换行）也一样：参数只在变量里，不进命令文字。
    func testScriptPathKeepsPlaceholdersInsideArgumentsInert() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pwned")
        let names = ["/d/\n; touch \(marker.path); ", "/d/z\"$a0\"z'$(touch \(marker.path))'"]
        let command = echoCommand(names)
        XCTAssertTrue(command.hasPrefix("sh -c "))
        let result = try run(command, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), command)
        XCTAssertEqual(split(result.output), names.map { Array($0.utf8) })
    }

    /// 真的建两个这样的文件，对它们跑属主 stat 的命令：只有 stat 在跑，什么都没被执行。
    func testOwnerStatOverCraftedNamesRunsOnlyStat() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pwned")
        // 文件名里不能有 `/`：用相对路径（命令在这个目录里跑）。
        let first = "; touch pwned; "
        let second = "z\"$a0\"z"
        for name in [first, second] {
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data()))
        }
        let paths = [first, second].map { directory.path + "/" + $0 }

        let result = try run(RemoteFileOperations.ownerStatCommand(paths: paths, escapedNames: true), in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(RemoteFileOperations.parseOwnerStatOutput(String(decoding: result.output, as: UTF8.self)).count, 2,
                       "两个文件都 stat 到了")
    }

    /// 随机的参数（满是 `"`、`$`、`a`、数字、引号、`;`、空格、反斜杠……）：sh 收到的就是这些参数，一个字节不差。
    func testRandomArgumentsArriveByteExact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alphabet = Array("\"$a0123456789'`;  \\|&()<>*?{}[]~#=%^.-_/\t!\n") + ["\u{FFFD}", "é", "中"]
        var generator = SystemRandomNumberGenerator()
        for round in 0..<200 {
            let count = Int.random(in: 1...12, using: &generator)
            let arguments = (0..<count).map { _ in
                String((0..<Int.random(in: 0...14, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            }
            let command = echoCommand(arguments)
            let result = try run(command, in: directory)
            XCTAssertEqual(result.status, 0, "第 \(round) 轮：\(command)")
            XCTAssertEqual(split(result.output), arguments.map { Array($0.utf8) }, "第 \(round) 轮：\(command)")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                          "第 \(round) 轮有东西被执行了：\(command)")
        }
    }
}

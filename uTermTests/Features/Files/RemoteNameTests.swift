import XCTest
@testable import uTerm

/// `RemoteName`：远程文件名的无损写法。核心性质是「字节 → 字符串 → 字节」恒等（于是不同的名字显示也不同），
/// 而且合法 UTF-8、用户手打的路径一个字节都不变。
final class RemoteNameTests: XCTestCase {

    func testValidUTF8NamesAreUnchanged() {
        for name in ["app.log", "测试报告.txt", "naïve café", "🐳 docker", "a b/c", ""] {
            XCTAssertEqual(RemoteName.display(Array(name.utf8)), name)
            XCTAssertEqual(RemoteName.bytes(name), Array(name.utf8))
        }
    }

    /// GBK 的「测试」「报告」「附件」有损解码都是 `����.txt`；无损写法各不相同，还原得回原样字节。
    func testCollidingGBKNamesStayDistinctAndRoundTrip() {
        let names: [[UInt8]] = [
            [0xB2, 0xE2, 0xCA, 0xD4] + Array(".txt".utf8),
            [0xB1, 0xA8, 0xB8, 0xE6] + Array(".txt".utf8),
            [0xB8, 0xBD, 0xBC, 0xFE] + Array(".txt".utf8),
        ]
        let lossy = Set(names.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(lossy.count, 1, "前提：有损解码下三个名字一样")
        let displayed = names.map { RemoteName.display($0) }
        XCTAssertEqual(Set(displayed).count, 3)
        for (raw, shown) in zip(names, displayed) {
            XCTAssertEqual(RemoteName.bytes(shown), raw)
        }
        XCTAssertTrue(displayed[0].hasPrefix("\u{FFFD}B2\u{2060}\u{FFFD}E2\u{2060}"), displayed[0])
    }

    /// 合法名字里本来就有的 U+FFFD 与 U+2060，和非法字节的转义分得开。
    func testLiteralReplacementAndWordJoinerAreDistinguishable() {
        let cases: [[UInt8]] = [
            Array("a\u{FFFD}.txt".utf8),
            [UInt8(ascii: "a"), 0xFF] + Array(".txt".utf8),
            Array("\u{FFFD}FF\u{2060}".utf8),          // 看起来像转义的合法名字
            Array("x\u{2060}y".utf8),
            Array("\u{FFFD}\u{2060}".utf8),
        ]
        let displayed = cases.map { RemoteName.display($0) }
        XCTAssertEqual(Set(displayed).count, cases.count)
        for (raw, shown) in zip(cases, displayed) {
            XCTAssertEqual(RemoteName.bytes(shown), raw, shown.debugDescription)
        }
        XCTAssertEqual(displayed[0], "a\u{FFFD}.txt", "不含 U+2060 的合法名字原样显示")
    }

    /// 随机字节串：显示后还原恒等（单射）。
    func testRandomByteStringsRoundTrip() {
        var generator = SystemRandomNumberGenerator()
        var seen: [String: [UInt8]] = [:]
        for _ in 0..<3000 {
            let length = Int.random(in: 0...12, using: &generator)
            let raw = (0..<length).map { _ -> UInt8 in
                // 偏向高位字节与几个敏感值，多撞到边界。
                let pool: [UInt8] = [0x80, 0xBF, 0xC0, 0xC2, 0xE0, 0xE2, 0x81, 0xA0, 0xED, 0xF0, 0xF4, 0xFF, 0xEF, 0xBD]
                return Bool.random(using: &generator) ? pool.randomElement(using: &generator)! : UInt8.random(in: 0...255, using: &generator)
            }
            let shown = RemoteName.display(raw)
            XCTAssertEqual(RemoteName.bytes(shown), raw, shown.debugDescription)
            if let previous = seen[shown] { XCTAssertEqual(previous, raw, "两个不同的名字显示成了同一个") }
            seen[shown] = raw
        }
    }

    /// 用户手打、命令行传来、从 exec 输出有损解码来的路径：不是转义序列的 U+FFFD 原样当字符。
    func testTypedAndLossyPathsAreUnaffected() {
        for path in ["/home/user/file.txt", "/srv/\u{FFFD}\u{FFFD}.txt", "/a\u{FFFD}B2.txt", "/a\u{FFFD}B"] {
            XCTAssertEqual(RemoteName.bytes(path), Array(path.utf8), path.debugDescription)
        }
    }

    /// 斜杠（多余的、末尾的）原样保留，转义只管名字里的字节。
    func testSlashesArePreserved() {
        let raw: [UInt8] = Array("/a//".utf8) + [0xB2] + Array("/b/".utf8)
        let shown = RemoteName.display(raw)
        XCTAssertEqual(shown, "/a//\u{FFFD}B2\u{2060}/b/")
        XCTAssertEqual(RemoteName.bytes(shown), raw)
    }

    // MARK: - 交给 shell 的路径

    /// 在本机用登录 shell `shell` 跑生成的命令，取 stdout 的原样字节（远端 exec 也是交给登录 shell 跑这一串）。
    private func run(_ command: String, in shell: String) throws -> [UInt8] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Array(data)
    }

    /// 参数原样回显出来：`printf '%s' "$a0"`。
    private func echoed(_ path: String, escaped: Bool = true, shell: String = "/bin/sh") throws -> [UInt8] {
        try run(RemotePath.shScript("printf '%s|' \(argument: 0)", arguments: [path], escapedNames: escaped), in: shell)
    }

    func testPlainPathsArriveUnchanged() throws {
        XCTAssertEqual(try echoed("/home/it's here"), Array("/home/it's here|".utf8))
        XCTAssertEqual(try echoed("/srv/-rf"), Array("/srv/-rf|".utf8))
    }

    /// 带转义的路径交给 shell 时还原成原样字节，`%`、引号、`-`、`!` 都不会被另作解释。
    func testEscapedPathsArriveAsTheirRawBytes() throws {
        let raw: [UInt8] = Array("/x/".utf8) + [UInt8(ascii: "-"), 0xB2, 0xE2, UInt8(ascii: "%"), UInt8(ascii: "'"),
                                                 UInt8(ascii: "!"), UInt8(ascii: "$")]
        XCTAssertEqual(try echoed(RemoteName.display(raw)), raw + Array("|".utf8))
    }

    /// 以换行结尾的名字：命令替换会吃掉结尾的换行，垫了哨兵 `x` 再去掉，名字一个字节都不少（否则就成了它的兄弟）。
    func testANameEndingInANewlineKeepsIt() throws {
        XCTAssertEqual(try echoed("/tmp/report\n"), Array("/tmp/report\n|".utf8))
        XCTAssertEqual(try echoed("/tmp/two\n\n"), Array("/tmp/two\n\n|".utf8))
        let raw: [UInt8] = Array("/tmp/".utf8) + [0xB2, 0x0A]
        XCTAssertEqual(try echoed(RemoteName.display(raw)), raw + Array("|".utf8))
    }

    /// 登录 shell 是 csh / tcsh、zsh 时一样：外层只是 `sh -c '…'`，里面没有换行、`!` 这类会被它们另作解释的字符。
    func testTheCommandWorksUnderCshAndZshLoginShells() throws {
        let raw: [UInt8] = Array("/x/a!b\n".utf8) + [0xB2]
        let path = RemoteName.display(raw)
        for shell in ["/bin/csh", "/bin/tcsh", "/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
            XCTAssertEqual(try echoed(path, shell: shell), raw + Array("|".utf8), shell)
        }
        let command = RemotePath.shScript("printf '%s|' \(argument: 0)", arguments: [path], escapedNames: true)
        XCTAssertTrue(command.hasPrefix("sh -c '"), command)
        XCTAssertFalse(command.contains("\n"), "命令行上不能有真的换行（csh 不认单引号里的换行）")
        XCTAssertFalse(command.contains("!"), "命令行上不能有 !（csh 单引号里也做历史展开）")
    }

    /// 名字本来就是合法 UTF-8 的 provider（配对过的 Mac）：长得像转义的名字原样传，不「还原」成别的字节。
    func testUnescapedProvidersPassNamesThatLookEscapedUnchanged() throws {
        let literal = "/Users/me/\u{FFFD}B2\u{2060}.txt"
        XCTAssertEqual(try echoed(literal, escaped: false), Array(literal.utf8) + Array("|".utf8))
        XCTAssertNotEqual(try echoed(literal, escaped: true), Array(literal.utf8) + Array("|".utf8))
    }

    // MARK: - 插进句子里

    /// 句子里的名字包在 FSI … PDI 里，名字本身一个字符都不动（转义的 U+2060 留着，和列表里显示的一样）。
    func testIsolatedWrapsWithoutAlteringTheName() {
        let escaped = RemoteName.display([0xB2, 0xE2] + Array(".txt".utf8))
        let isolated = RemoteName.isolated(escaped)
        XCTAssertEqual(Array(isolated.unicodeScalars.first.map { [$0] } ?? []), ["\u{2068}"])
        XCTAssertEqual(isolated.unicodeScalars.last, "\u{2069}")
        XCTAssertEqual(Array(isolated.unicodeScalars.dropFirst().dropLast()), Array(escaped.unicodeScalars))
        // 名字里有从右往左的覆盖符：被关在隔离区里，句子后面的字不受影响。
        let hostile = RemoteName.isolated("evil\u{202E}gpj.exe")
        XCTAssertTrue(hostile.hasSuffix("\u{2069}"))
    }
}


import XCTest
@testable import uTerm

final class ClaudeReverseLineScannerTests: XCTestCase {
    /// 用给定块大小从后往前读完整份，返回按文件先后排的行。
    private func readAll(_ data: Data, chunk: Int, maxLine: Int = 1 << 20, head: Int = 16)
        -> [ClaudeReverseLineScanner.Line] {
        var scanner = ClaudeReverseLineScanner(fileSize: UInt64(data.count), maxLineBytes: maxLine, headBytes: head)
        var newestFirst: [ClaudeReverseLineScanner.Line] = []
        while let range = scanner.nextRange(chunkSize: chunk) {
            let piece = data.subdata(in: Int(range.offset)..<Int(range.offset) + range.length)
            newestFirst.append(contentsOf: scanner.feed(piece))
        }
        if let first = scanner.finish() { newestFirst.append(first) }
        XCTAssertTrue(scanner.isAtStart)
        return newestFirst.reversed()
    }

    private func texts(_ lines: [ClaudeReverseLineScanner.Line]) -> [String] {
        lines.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    func testLinesAcrossEveryChunkSizeMatchForwardSplit() {
        let lines = ["{\"a\":1}", "", "第二行，带中文", String(repeating: "x", count: 50), "last"]
        let data = Data(lines.joined(separator: "\n").utf8)
        let expected = lines.filter { !$0.isEmpty }
        for chunk in [1, 2, 3, 7, 16, 64, 1000] {
            let result = readAll(data, chunk: chunk)
            XCTAssertEqual(texts(result), expected, "chunk \(chunk)")
            XCTAssertTrue(result.allSatisfy { !$0.isTruncated })
        }
    }

    func testOffsetsAndLengthsPointIntoTheFile() {
        let data = Data("one\ntwo\r\nthree\n".utf8)
        let result = readAll(data, chunk: 4)
        XCTAssertEqual(texts(result), ["one", "two", "three"])
        XCTAssertEqual(result.map(\.offset), [0, 4, 9])
        for line in result {
            let slice = data.subdata(in: Int(line.offset)..<Int(line.offset) + line.length)
            XCTAssertTrue(String(decoding: slice, as: UTF8.self).hasPrefix(String(decoding: line.bytes, as: UTF8.self)))
        }
    }

    func testOversizedLineKeepsOnlyItsHead() {
        let big = "HEAD-" + String(repeating: "z", count: 500)
        let data = Data(["small", big, "tail"].joined(separator: "\n").utf8)
        for chunk in [3, 50, 4096] {
            let result = readAll(data, chunk: chunk, maxLine: 100, head: 8)
            XCTAssertEqual(result.count, 3, "chunk \(chunk)")
            XCTAssertEqual(texts(result)[0], "small")
            XCTAssertTrue(result[1].isTruncated)
            XCTAssertEqual(String(decoding: result[1].bytes, as: UTF8.self), "HEAD-zzz")
            XCTAssertEqual(result[1].length, big.utf8.count)
            XCTAssertEqual(result[1].offset, 6)
            XCTAssertEqual(texts(result)[2], "tail")
            XCTAssertFalse(result[2].isTruncated)
        }
    }

    func testEmptyAndNewlineOnlyFiles() {
        XCTAssertEqual(readAll(Data(), chunk: 8).count, 0)
        XCTAssertEqual(readAll(Data("\n\n\n".utf8), chunk: 2).count, 0)
    }
}

final class ClaudeTranscriptPagerTests: XCTestCase {
    private let path = "/home/user/.claude/projects/-home-user-projects-demo/\(ClaudeFixture.sessionID).jsonl"

    private func makeFile(turns: Int) -> Data {
        var lines: [String] = [ClaudeFixture.noise(0)]
        for index in 0..<turns {
            lines.append(ClaudeFixture.userText("问题 \(index)", uuid: "u-\(index)"))
            lines.append(ClaudeFixture.assistant(
                ClaudeFixture.toolUse(id: "toolu_\(index)", name: "Read", input: #"{"file_path":"/f\#(index)"}"#)))
            lines.append(ClaudeFixture.noise(index + 1))
            lines.append(ClaudeFixture.toolResult(id: "toolu_\(index)", text: "内容 \(index)"))
            lines.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("回答 \(index)")))
        }
        lines.append(ClaudeFixture.aiTitle("演示"))
        return ClaudeFixture.file(lines)
    }

    func testPagesBackwardsAndKeepsChronologicalOrder() async throws {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: makeFile(turns: 30), mtime: Date())
        // 小块、小页：跨块的行、跨页的工具调用和结果都会出现。
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 700, pageItems: 10, pageBytes: 1 << 20)
        var all: [AgentTranscriptItem] = []
        var pages = 0
        var reachedStart = false
        while !reachedStart, pages < 50 {
            let page = try await pager.loadPrevious()
            all = AgentTranscriptAssembler.attachResults(page.items + all)
            reachedStart = page.reachedStart
            pages += 1
        }
        XCTAssertGreaterThan(pages, 3)
        // 30 轮 × （问题 + 带结果的调用 + 回答）。
        XCTAssertEqual(all.count, 90)
        XCTAssertEqual(all.first?.kind, .userText("问题 0"))
        XCTAssertEqual(all.last?.kind, .assistantText("回答 29"))
        for (index, item) in all.enumerated() where index % 3 == 1 {
            guard case .toolCall(let call) = item.kind else { return XCTFail("\(index): \(item.kind)") }
            XCTAssertEqual(call.result?.content.text, "内容 \(index / 3)")
        }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let empty = try await pager.loadPrevious()
        XCTAssertTrue(empty.items.isEmpty && empty.reachedStart)
    }

    func testFirstPageIsTheEndOfTheFile() async throws {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: makeFile(turns: 200), mtime: Date())
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 4096, pageItems: 6, pageBytes: 1 << 20)
        let page = try await pager.loadPrevious()
        XCTAssertFalse(page.reachedStart)
        XCTAssertEqual(page.items.last?.kind, .assistantText("回答 199"))
        // 只读了末尾几块，没有把整份读进来。
        let reads = await sftp.rangeReads
        XCTAssertLessThan(reads.reduce(0) { $0 + $1.length }, 16 * 1024)
    }

    func testOversizedLineInTheMiddleShowsPlaceholder() async throws {
        let sftp = MockSFTP()
        let huge = ClaudeFixture.toolResult(id: "x", text: String(repeating: "大", count: 4000))
        let data = ClaudeFixture.file([ClaudeFixture.userText("前"), huge, ClaudeFixture.userText("后")])
        await sftp.setFile(path, data: data, mtime: Date())
        let pager = ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 1000, pageItems: 100,
                                          pageBytes: 1 << 20, maxLineBytes: 2000)
        let page = try await pager.loadPrevious()
        XCTAssertTrue(page.reachedStart)
        XCTAssertEqual(page.items.map(\.kind), [.userText("前"), .oversized(bytes: huge.utf8.count), .userText("后")])
    }
}

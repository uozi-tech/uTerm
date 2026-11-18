import XCTest
@testable import uTerm

final class RemoteDesktopPasteChunkTests: XCTestCase {

    private func chunks(_ payload: Data, id: UInt32 = 1, size: Int = 1000) -> [RemoteDesktopPasteChunk] {
        stride(from: 0, to: payload.count, by: size).map { start in
            let end = min(payload.count, start + size)
            return RemoteDesktopPasteChunk(pasteID: id, offset: UInt32(start), total: UInt32(payload.count),
                                           bytes: payload.subdata(in: start..<end))
        }
    }

    func test_chunk_round_trips() throws {
        let chunk = RemoteDesktopPasteChunk(pasteID: 7, offset: 1024, total: 4096, bytes: Data([1, 2, 3]))
        XCTAssertEqual(try RemoteDesktopPasteChunk(decoding: chunk.encoded()), chunk)
        XCTAssertThrowsError(try RemoteDesktopPasteChunk(decoding: Data([0, 0])))
    }

    func test_chunks_rebuild_the_paste() {
        let paste = RemoteDesktopPaste.png(Data(repeating: 9, count: 5500))
        var assembler = RemoteDesktopPasteAssembler()
        let all = chunks(paste.encoded())
        for chunk in all.dropLast() { XCTAssertNil(assembler.receive(chunk)) }
        XCTAssertEqual(assembler.receive(all[all.count - 1]), paste)
    }

    func test_a_new_paste_replaces_an_unfinished_one() {
        let first = chunks(RemoteDesktopPaste.png(Data(repeating: 1, count: 5000)).encoded(), id: 1)
        let second = RemoteDesktopPaste.text("后来的")
        var assembler = RemoteDesktopPasteAssembler()
        XCTAssertNil(assembler.receive(first[0]))
        XCTAssertEqual(assembler.receive(chunks(second.encoded(), id: 2)[0]), second)
        XCTAssertNil(assembler.receive(first[1]), "旧的剩余部分没人要了")
    }

    /// 对端出错或恶意：偏移接不上、长度不一致、声称超大，都不能拼出东西来，也不能占内存。
    func test_malformed_sequences_are_dropped() {
        let all = chunks(RemoteDesktopPaste.png(Data(repeating: 1, count: 5000)).encoded())
        var skipped = RemoteDesktopPasteAssembler()
        XCTAssertNil(skipped.receive(all[0]))
        XCTAssertNil(skipped.receive(all[2]), "跳过了一块")
        XCTAssertNil(skipped.receive(all[1]), "出错之后这一次已经作废")

        var late = RemoteDesktopPasteAssembler()
        XCTAssertNil(late.receive(all[1]), "没有开头")

        var liar = RemoteDesktopPasteAssembler()
        XCTAssertNil(liar.receive(RemoteDesktopPasteChunk(pasteID: 1, offset: 0, total: .max, bytes: Data([1]))))
        XCTAssertNil(liar.receive(RemoteDesktopPasteChunk(pasteID: 1, offset: 0, total: 0, bytes: Data())))

        var overflow = RemoteDesktopPasteAssembler()
        XCTAssertNil(overflow.receive(RemoteDesktopPasteChunk(pasteID: 1, offset: 0, total: 4, bytes: Data(count: 100))))

        var garbage = RemoteDesktopPasteAssembler()
        XCTAssertNil(garbage.receive(RemoteDesktopPasteChunk(pasteID: 1, offset: 0, total: 3, bytes: Data([99, 1, 2]))),
                     "拼完解不开")
    }

    // MARK: - 文件（视频）

    private func fileChunks(_ content: Data, id: UInt32 = 1, name: String = "clip.mov", size: Int = 1000)
        -> [RemoteDesktopPasteFileChunk] {
        stride(from: 0, to: content.count, by: size).map { start in
            RemoteDesktopPasteFileChunk(pasteID: id, offset: UInt64(start), total: UInt64(content.count), name: name,
                                        bytes: content.subdata(in: start..<min(content.count, start + size)))
        }
    }

    private func scratchRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PastedFilesTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func test_file_chunk_round_trips() throws {
        let chunk = RemoteDesktopPasteFileChunk(pasteID: 7, offset: 5 << 32, total: 6 << 32, name: "假期 01.mov",
                                                bytes: Data([1, 2, 3]))
        XCTAssertEqual(try RemoteDesktopPasteFileChunk(decoding: chunk.encoded()), chunk)
        XCTAssertThrowsError(try RemoteDesktopPasteFileChunk(decoding: Data([0, 0, 0])))
        XCTAssertEqual(RemoteMessage.Kind.desktopPasteFile.rawValue, 58)
        XCTAssertTrue(RemoteConstants.localFeatures.contains("desktop-paste-files"))
    }

    func test_file_chunks_are_written_to_a_file_with_the_given_name() throws {
        let content = Data((0..<5500).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let receiver = RemotePastedFileReceiver(root: scratchRoot())
        let all = fileChunks(content)
        for chunk in all.dropLast() { XCTAssertNil(receiver.receive(chunk)) }
        let url = try XCTUnwrap(receiver.receive(all[all.count - 1]))
        XCTAssertEqual(url.lastPathComponent, "clip.mov")
        XCTAssertEqual(try Data(contentsOf: url), content)
    }

    func test_a_new_file_replaces_an_unfinished_one_and_removes_it() throws {
        let root = scratchRoot()
        let receiver = RemotePastedFileReceiver(root: root)
        let first = fileChunks(Data(repeating: 1, count: 5000), id: 1, name: "a.mov")
        XCTAssertNil(receiver.receive(first[0]))
        let second = Data(repeating: 2, count: 300)
        let url = try XCTUnwrap(receiver.receive(fileChunks(second, id: 2, name: "b.mp4")[0]))
        XCTAssertEqual(try Data(contentsOf: url), second)
        XCTAssertNil(receiver.receive(first[1]), "旧的剩余部分没人要了")
        // 没传完的那个不留在磁盘上。
        let left = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(left.count, 1)
    }

    /// 对端出错或恶意：偏移接不上、声称超大、文件名带路径，都不能写到别处去，也不留半个文件。
    func test_malformed_file_sequences_are_dropped() throws {
        let root = scratchRoot()
        let all = fileChunks(Data(repeating: 1, count: 5000))
        let skipped = RemotePastedFileReceiver(root: root)
        XCTAssertNil(skipped.receive(all[0]))
        XCTAssertNil(skipped.receive(all[2]), "跳过了一块")
        XCTAssertNil(skipped.receive(all[1]), "出错之后这一次已经作废")
        XCTAssertNil(RemotePastedFileReceiver(root: root).receive(all[1]), "没有开头")
        XCTAssertNil(RemotePastedFileReceiver(root: root).receive(
            RemoteDesktopPasteFileChunk(pasteID: 1, offset: 0, total: .max, name: "x.mov", bytes: Data([1]))))
        XCTAssertNil(RemotePastedFileReceiver(root: root).receive(
            RemoteDesktopPasteFileChunk(pasteID: 1, offset: 0, total: 4, name: "x.mov", bytes: Data(count: 100))))
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "没收齐的不留在磁盘上：\(leftovers)")

        XCTAssertEqual(RemotePastedFileReceiver.safeName("../../Library/LaunchAgents/evil.plist"), "evil.plist")
        XCTAssertEqual(RemotePastedFileReceiver.safeName("a/b:c.mov"), "c.mov")
        XCTAssertEqual(RemotePastedFileReceiver.safeName(".."), "video.mov")
        XCTAssertEqual(RemotePastedFileReceiver.safeName(""), "video.mov")
        let escaped = try XCTUnwrap(RemotePastedFileReceiver(root: root).receive(
            RemoteDesktopPasteFileChunk(pasteID: 1, offset: 0, total: 1, name: "../../escape.mov", bytes: Data([1]))))
        XCTAssertTrue(escaped.path.hasPrefix(root.path + "/"), "写到了目录外面：\(escaped.path)")
    }

    func test_kind_number_is_stable() {
        XCTAssertEqual(RemoteMessage.Kind.desktopPasteChunk.rawValue, 19)
    }
}

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

    func test_kind_number_is_stable() {
        XCTAssertEqual(RemoteMessage.Kind.desktopPasteChunk.rawValue, 19)
    }
}

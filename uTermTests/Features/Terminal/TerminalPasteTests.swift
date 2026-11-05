import XCTest
@testable import uTerm

/// 两端共用的粘贴 / 贴图送达帮手。
@MainActor
final class TerminalPasteTests: XCTestCase {

    private actor FakeReceiver: TerminalImageReceiving {
        nonisolated let outputStream: AsyncStream<Data>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let programsCanReadMacClipboard = false
        private let result: Result<TerminalImageDelivery, TerminalImageError>

        init(_ result: Result<TerminalImageDelivery, TerminalImageError>) {
            self.result = result
            outputStream = AsyncStream { $0.finish() }
            exitStream = AsyncStream { $0.finish() }
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func deliverImage(_ image: uTerm.TerminalImage) async throws -> TerminalImageDelivery {
            try result.get()
        }
    }

    private let image = uTerm.TerminalImage(format: .png, data: Data([0x89, 0x50]))

    func test_wrap_without_bracketed_paste_sends_plain_text() {
        XCTAssertEqual(TerminalPaste.wrap("ls -la\n", bracketed: false), Data("ls -la\n".utf8))
    }

    func test_wrap_with_bracketed_paste_adds_start_and_end_markers() {
        XCTAssertEqual(TerminalPaste.wrap("echo hi", bracketed: true),
                       Data("\u{1b}[200~echo hi\u{1b}[201~".utf8))
    }

    func test_wrap_keeps_non_ascii_text_intact() {
        XCTAssertEqual(TerminalPaste.wrap("中文", bracketed: true),
                       Data("\u{1b}[200~中文\u{1b}[201~".utf8))
    }

    func test_file_delivery_pastes_path_followed_by_space() async throws {
        var pasted: [String] = []
        let delivery = try await TerminalPaste.deliver(
            image: image, to: FakeReceiver(.success(.file(path: "/tmp/a.png")))) { pasted.append($0) }
        XCTAssertEqual(delivery, .file(path: "/tmp/a.png"))
        XCTAssertEqual(pasted, ["/tmp/a.png "])
    }

    func test_clipboard_delivery_types_nothing() async throws {
        var pasted: [String] = []
        let delivery = try await TerminalPaste.deliver(
            image: image, to: FakeReceiver(.success(.clipboard))) { pasted.append($0) }
        XCTAssertEqual(delivery, .clipboard)
        XCTAssertEqual(pasted, [])
    }

    func test_failed_delivery_throws_and_types_nothing() async {
        var pasted: [String] = []
        do {
            try await TerminalPaste.deliver(
                image: image, to: FakeReceiver(.failure(.notConnected))) { pasted.append($0) }
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error.localizedDescription, TerminalImageError.notConnected.localizedDescription)
        }
        XCTAssertEqual(pasted, [])
    }
}

import Foundation
import XCTest
@testable import uTerm

/// 不建画面的假 surface：泵只喂影子终端。
nonisolated final class NullTerminalSurface: TerminalSurfaceSink, @unchecked Sendable {
    func receive(_ data: Data) {}
    func receiveReplay(_ data: Data) {}
    func discardPendingOutput() -> Int { 0 }
    func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {}
}

/// 镜像的接收端（「手机」）：一台影子终端 + 一台输出泵，和真手机的 `MobileTerminalController` 同一个形态，只是不建画面。
/// 快照与实时字节从 `TerminalOutputItem` 流进来（`RemoteTerminalBackend.outputItems`，或者测试自己拼的流）。
nonisolated final class MirrorPhone: @unchecked Sendable {
    let shadow: ShadowTerminal
    let pump: TerminalOutputPump
    private let lock = NSLock()
    private var snapshotCount = 0
    private var byteCount = 0

    /// 回滚上限默认和 Mac 会话用的同一个值（`TerminalSettings`），两边的总行数才比得了。
    init(cols: Int, rows: Int, scrollbackLines: Int = TerminalSettings.read().scrollback) {
        shadow = ShadowTerminal(cols: UInt16(cols), rows: UInt16(rows),
                                options: TerminalScrollbackLimits(lines: scrollbackLines).shadowOptions)
        pump = TerminalOutputPump(shadow: shadow, surface: NullTerminalSurface())
    }

    /// 收到的整屏快照张数、原样字节数。
    var snapshots: Int { lock.withLock { snapshotCount } }
    var outputBytes: Int { lock.withLock { byteCount } }

    /// 开始吃一条后端输出（按到达顺序：快照还原进影子终端，字节接着喂）。
    func start(_ items: AsyncStream<TerminalOutputItem>) {
        let counted = AsyncStream<TerminalOutputItem> { continuation in
            let task = Task.detached { [weak self] in
                for await item in items {
                    self?.count(item)
                    continuation.yield(item)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        pump.reset()
        pump.start(counted)
    }

    func stop() { pump.reset() }

    /// 手机自己的终端改尺寸（转屏、键盘、Duo 展开）：真机上是 surface 报来新网格时改影子终端。
    func resize(cols: Int, rows: Int) {
        shadow.resize(cols: UInt16(cols), rows: UInt16(rows))
    }

    private func count(_ item: TerminalOutputItem) {
        lock.withLock {
            switch item {
            case .snapshot: snapshotCount += 1
            case .bytes(let bytes): byteCount += bytes.count
            }
        }
    }
}

extension ShadowTerminal {
    /// 和另一台影子终端比镜像要保证一致的那几样；空 = 一致。两边还在吃字节时读到的是中间态，放在轮询里用。
    /// `includingHistory`：连回滚的行数也比（两边的回滚上限相同、历史没到上限时才有意义——到了上限按页裁，
    /// 还原出来的终端页的排法不一样，裁掉的行数可以差几行）。
    func mirrorDifferences(from other: ShadowTerminal, includingHistory: Bool = true) -> [String: String] {
        var diff: [String: String] = [:]
        let mine = size, theirs = other.size
        if mine.cols != theirs.cols || mine.rows != theirs.rows {
            diff["尺寸"] = "\(mine.cols)×\(mine.rows) ≠ \(theirs.cols)×\(theirs.rows)"
        }
        if cursor != other.cursor { diff["光标"] = "\(cursor) ≠ \(other.cursor)" }
        if isOnAlternateScreen != other.isOnAlternateScreen {
            diff["备用屏"] = "\(isOnAlternateScreen) ≠ \(other.isOnAlternateScreen)"
        }
        if title != other.title { diff["标题"] = "\(title) ≠ \(other.title)" }
        if includingHistory, totalRows != other.totalRows { diff["总行数"] = "\(totalRows) ≠ \(other.totalRows)" }
        let a = viewportText(), b = other.viewportText()
        if a != b {
            let left = a.components(separatedBy: "\n"), right = b.components(separatedBy: "\n")
            let row = (0..<min(left.count, right.count)).first { left[$0] != right[$0] } ?? min(left.count, right.count)
            diff["视口"] = "第 \(row) 行起不同：「\(row < left.count ? left[row] : "")」≠「\(row < right.count ? right[row] : "")」"
        }
        return diff
    }
}

/// 录下来的终端语料（`uTermTests/Support/Fixtures/TerminalCorpus/`）。
enum TerminalCorpus {
    static func bytes(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: MirrorPhone.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"),
                                "找不到语料 \(name)", file: file, line: line)
        return try Data(contentsOf: url)
    }
}

import Foundation

/// 检查点的数据：版本头 + 程序状态 + 影子终端的二进制快照，退出时另带一份回放流。
///
/// 二进制快照只有快照格式相同的引擎解得开（`TerminalEngineVersion.snapshotsCompatible`）。回放流是重画这一屏的 VT 字节
/// （`ShadowTerminal.replay`，和回前台时灌进画面的同一种流），哪个版本的引擎都吃得下：换了引擎之后接回的旧终端靠它
/// 还原画面（文字、颜色、光标、备用屏、最近一段回滚；命令标记这类引擎内部的状态不在里面）。拍它要几毫秒到几十毫秒：
/// Mac 本机终端只在退出时拍（换版本一定先退出，平时的检查点不带）；iOS 经主机上的保持进程存的每一张都带
/// （`TerminalCheckpoint.addingReplay`，App Store 更新前没有退出流程，哪一张都可能是最后一张）。
///
/// 两种格式：不带回放流的仍是第 2 版（和以前逐字节相同，同引擎的旧版本照样读得懂）；带回放流的是第 3 版，
/// 在程序状态之后多一段 `[u32 长度][回放流]`。旧版本认不出第 3 版的头，当没有检查点。
nonisolated enum TerminalCheckpointBlob {
    private static let magic = Array("uTermCP\u{2}".utf8)
    private static let magicWithReplay = Array("uTermCP\u{3}".utf8)

    /// `programStatus`：`ProgramStatusJournal.encoded`（引擎的快照里不带程序状态，那是宿主记的）。
    /// `replay`：换了引擎时用的回放流，见类型注释。
    static func encode(snapshot: Data, programStatus: Data? = nil, replay: Data? = nil,
                       engine: String = TerminalEngineVersion.current) -> [UInt8] {
        let version = Array(engine.utf8.prefix(255))
        let status = programStatus ?? Data()
        var blob = (replay == nil ? magic : magicWithReplay) + [UInt8(version.count)] + version
        blob += lengthPrefix(status.count) + status
        if let replay { blob += lengthPrefix(replay.count) + replay }
        return blob + snapshot
    }

    /// 快照部分；快照格式和现在的引擎不同返回 nil。
    static func decode(_ blob: [UInt8], engine: String = TerminalEngineVersion.current) -> Data? {
        decodeContents(blob, engine: engine)?.snapshot
    }

    static func decodeContents(_ blob: [UInt8], engine: String = TerminalEngineVersion.current)
        -> (snapshot: Data, programStatus: Data?)? {
        guard let parts = split(blob),
              TerminalEngineVersion.snapshotsCompatible(String(decoding: parts.engine, as: UTF8.self), engine) else { return nil }
        return (parts.snapshot, parts.programStatus)
    }

    /// 程序状态那一段，不核引擎版本：状态是宿主记的（`ProgramStatusJournal` 的 JSON），和快照格式无关，换了引擎、
    /// 快照用不了时照样对应着检查点那个字节位置。
    static func decodeProgramStatus(_ blob: [UInt8]) -> Data? {
        split(blob)?.programStatus
    }

    /// 回放流，不核引擎版本（VT 字节和引擎无关）。没带的返回 nil。
    static func decodeReplay(_ blob: [UInt8]) -> Data? {
        split(blob)?.replay
    }

    private static func lengthPrefix(_ count: Int) -> [UInt8] {
        let length = UInt32(count)
        return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
    }

    private static func split(_ blob: [UInt8])
        -> (engine: [UInt8], programStatus: Data?, replay: Data?, snapshot: Data)? {
        guard blob.count > magic.count else { return nil }
        let head = Array(blob.prefix(magic.count))
        guard head == magic || head == magicWithReplay else { return nil }
        let versionLength = Int(blob[magic.count])
        var cursor = magic.count + 1
        guard blob.count >= cursor + versionLength else { return nil }
        let engine = Array(blob[cursor..<(cursor + versionLength)])
        cursor += versionLength

        func section() -> Data?? {
            guard blob.count >= cursor + 4 else { return nil }
            let length = blob[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | Int($1) }
            cursor += 4
            guard blob.count >= cursor + length else { return nil }
            defer { cursor += length }
            return .some(length > 0 ? Data(blob[cursor..<(cursor + length)]) : nil)
        }

        guard let status = section() else { return nil }
        var replay: Data?
        if head == magicWithReplay {
            guard let section = section() else { return nil }
            replay = section
        }
        guard blob.count > cursor else { return nil }
        return (engine, status, replay, Data(blob[cursor...]))
    }
}

/// 一张检查点：数据（`TerminalCheckpointBlob`）和拍它时影子的网格。
nonisolated struct TerminalCheckpoint: Sendable {
    var blob: [UInt8]
    var cols: UInt16
    var rows: UInt16
}

nonisolated extension TerminalCheckpoint {
    /// 加上回放流（经主机上的保持进程存的检查点用：iOS 被系统结束、App Store 换了版本都没有退出流程，存哪一张都可能是
    /// 最后一张）。快照已经裁过回滚，拍回放流几毫秒；任何线程可调，别在泵的锁里调。拍不出来原样返回。
    func addingReplay() -> TerminalCheckpoint {
        guard let contents = TerminalCheckpointBlob.decodeContents(blob),
              let replay = try? ShadowTerminal.replayStream(fromSnapshot: contents.snapshot) else { return self }
        return TerminalCheckpoint(blob: TerminalCheckpointBlob.encode(snapshot: contents.snapshot, programStatus: contents.programStatus,
                                                                       replay: replay),
                                  cols: cols, rows: rows)
    }
}

nonisolated extension TerminalCheckpointBlob {
    /// 这张检查点能还原成的快照：快照格式和现在的引擎相同就是它；不同（App 更新换了引擎）但带着回放流时，把回放流按存的
    /// 时候的尺寸在现在的引擎里重画一遍再拍一张——之后照常按快照还原，尺寸、两个屏都由快照带着。都不行返回 nil。
    /// `cols` / `rows`：检查点记的网格（回放流是按它生成的）。任何线程可调。
    static func restorableSnapshot(_ blob: [UInt8], cols: UInt16, rows: UInt16) -> Data? {
        if let snapshot = decode(blob) { return snapshot }
        guard let replay = decodeReplay(blob) else { return nil }
        return ShadowTerminal.snapshot(redrawing: replay, cols: cols, rows: rows, scrollbackLines: replayRedrawScrollback)
    }

    /// 重画回放流的临时终端的回滚上限：回放流只带最近两千行（`TerminalHeldCheckpoints.replayScrollbackLines`、
    /// `HostHolder.checkpointScrollbackLines`），留足余量。还原进影子时按影子自己的上限再裁。
    private static let replayRedrawScrollback = 10_000
}

/// 会话留在别处（主机上的保持进程）的后端和终端之间的两件事：拍检查点、收还原出来的程序状态。
/// 两个闭包都在输出泵喂字节的那条线程上、拿着泵的锁调（`TerminalOutputItem.afterFed`），所以和字节流上的位置严格对应。
nonisolated struct TerminalCheckpointHooks: Sendable {
    /// 此刻影子的状态。拍不了返回 nil。
    var capture: @Sendable () -> TerminalCheckpoint?
    /// 接回时检查点里存着的程序状态（`ProgramStatusJournal.encoded`）。排在检查点之后的那段历史字节之前。
    var restoreProgramStatus: @Sendable (Data) -> Void
}

/// 能把终端状态存到会话那头的后端：App 被系统结束后重新打开，从检查点接回画面。
protocol CheckpointingTerminalBackend: TerminalBackend {
    /// 建连之前设。
    nonisolated func setCheckpointHooks(_ hooks: TerminalCheckpointHooks)
    /// 现在存一张（App 进后台时调）。没有新输出、没接着会话时什么都不做。
    func saveCheckpoint() async
}

nonisolated extension TerminalOutputPump {
    /// 拍一张检查点。要在泵的锁里调（`afterFed` 同步点、`performWhileFeedingPaused`）。
    /// `scrollbackLines`：只带最近这么多行回滚（经网络上传的检查点用，整段回滚一张能有几 MB）；nil = 全量。
    func makeCheckpoint(scrollbackLines: Int?, programStatus: Data?) -> TerminalCheckpoint? {
        let snapshot = scrollbackLines.map { try? shadow.snapshot(scrollbackLines: $0) } ?? (try? shadow.snapshot())
        guard let snapshot else { return nil }
        let size = shadow.size
        return TerminalCheckpoint(blob: TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: programStatus),
                                  cols: UInt16(clamping: size.cols), rows: UInt16(clamping: size.rows))
    }
}

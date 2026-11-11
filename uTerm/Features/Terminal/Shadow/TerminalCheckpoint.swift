import Foundation

/// 检查点的数据：版本头 + 程序状态 + 影子终端的二进制快照。版本头认不出来或者和现在的引擎不是同一个版本，就当没有检查点。
nonisolated enum TerminalCheckpointBlob {
    private static let magic = Array("uTermCP\u{2}".utf8)

    /// `programStatus`：`ProgramStatusJournal.encoded`（引擎的快照里不带程序状态，那是宿主记的）。
    static func encode(snapshot: Data, programStatus: Data? = nil, engine: String = TerminalEngineVersion.current) -> [UInt8] {
        let version = Array(engine.utf8.prefix(255))
        let status = programStatus ?? Data()
        let length = UInt32(status.count)
        let lengthBytes = [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        return magic + [UInt8(version.count)] + version + lengthBytes + status + snapshot
    }

    /// 快照部分；不是这个引擎版本存的返回 nil。
    static func decode(_ blob: [UInt8], engine: String = TerminalEngineVersion.current) -> Data? {
        decodeContents(blob, engine: engine)?.snapshot
    }

    static func decodeContents(_ blob: [UInt8], engine: String = TerminalEngineVersion.current)
        -> (snapshot: Data, programStatus: Data?)? {
        guard let parts = split(blob), parts.engine == Array(engine.utf8.prefix(255)) else { return nil }
        return (parts.snapshot, parts.programStatus)
    }

    /// 程序状态那一段，不核引擎版本：状态是宿主记的（`ProgramStatusJournal` 的 JSON），和快照格式无关，换了引擎、
    /// 快照用不了时照样对应着检查点那个字节位置。
    static func decodeProgramStatus(_ blob: [UInt8]) -> Data? {
        split(blob)?.programStatus
    }

    private static func split(_ blob: [UInt8]) -> (engine: [UInt8], programStatus: Data?, snapshot: Data)? {
        guard blob.count > magic.count, Array(blob.prefix(magic.count)) == magic else { return nil }
        let versionLength = Int(blob[magic.count])
        var cursor = magic.count + 1
        guard blob.count >= cursor + versionLength + 4 else { return nil }
        let engine = Array(blob[cursor..<(cursor + versionLength)])
        cursor += versionLength
        let statusLength = blob[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | Int($1) }
        cursor += 4
        guard blob.count > cursor + statusLength else { return nil }
        let status = statusLength > 0 ? Data(blob[cursor..<(cursor + statusLength)]) : nil
        return (engine, status, Data(blob[(cursor + statusLength)...]))
    }
}

/// 一张检查点：数据（`TerminalCheckpointBlob`）和拍它时影子的网格。
nonisolated struct TerminalCheckpoint: Sendable {
    var blob: [UInt8]
    var cols: UInt16
    var rows: UInt16
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

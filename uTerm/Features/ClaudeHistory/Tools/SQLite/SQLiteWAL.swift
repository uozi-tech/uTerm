import Foundation

/// 一份 WAL 文件（`<库>-wal`）里能用的部分：照 SQLite 自己在没有 `-shm` 时恢复 WAL 的规则（`walIndexRecover`）
/// 从头往后验帧，停在第一帧对不上的地方，只认最后一次提交（commit 帧）之前的帧。
///
/// 为什么自己做：远端的库只能把字节读回来、在内存里打开（不能在主机上跑 `sqlite3`——它会写 `-shm`；也不能落到本机的
/// 临时文件），而 `sqlite3_deserialize` 出来的内存库不支持 WAL。所以这里先把提交过的帧盖到主文件的副本上，
/// 再交给 SQLite，得到的就是「此刻一个新连接看到的库」。
nonisolated struct SQLiteWALIndex: Equatable, Sendable {
    let pageSize: Int
    /// WAL 头的 32 字节。写的一方重置 WAL（全部并回主文件之后从头写）时 salt 会变：头没变 = 之前验过的帧原样还在。
    let header: Data
    /// 每一页最后一次提交时的内容在 WAL 字节里从哪开始（帧头之后）。
    let pages: [UInt32: Int]
    /// 最后一次提交之后库一共多少页；一次提交都没有为 nil（这时 WAL 等于没有）。
    let databasePages: UInt32?
    /// 最后一个 commit 帧的末尾。之后的字节是还没提交（可能会被下一个事务覆盖）或写到一半的帧，下次接着读要从这里开始。
    let committedEnd: Int
    /// 提交过的帧数、验过的帧数（含最后一次提交之后的）。只用来报数。
    let committedFrames: Int
    let validFrames: Int
}

nonisolated enum SQLiteWAL {
    static let headerBytes = 32
    static let frameHeaderBytes = 24
    private static let magicLittleEndian: UInt32 = 0x377F_0682
    private static let magicBigEndian: UInt32 = 0x377F_0683
    private static let formatVersion: UInt32 = 3_007_000

    /// 解析 WAL。头坏了、不是 WAL、没有一次提交，SQLite 都当作 WAL 不存在，这里返回的 `databasePages` 为 nil
    /// （头本身读不出来时整个返回 nil）。
    static func index(_ wal: Data) -> SQLiteWALIndex? {
        guard wal.count >= headerBytes else { return nil }
        return wal.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SQLiteWALIndex? in
            let magic = readUInt32(raw, 0)
            guard magic == magicLittleEndian || magic == magicBigEndian,
                  readUInt32(raw, 4) == formatVersion else { return nil }
            let pageSize = Int(readUInt32(raw, 8))
            guard pageSize >= 512, pageSize <= 65_536, pageSize & (pageSize - 1) == 0 else { return nil }
            let bigEndian = magic == magicBigEndian
            let salt1 = readUInt32(raw, 16), salt2 = readUInt32(raw, 20)
            var sum = checksum(raw, from: 0, count: 24, seed: (0, 0), bigEndian: bigEndian)
            let header = Data(wal.prefix(headerBytes))
            guard sum.0 == readUInt32(raw, 24), sum.1 == readUInt32(raw, 28) else {
                return SQLiteWALIndex(pageSize: pageSize, header: header, pages: [:], databasePages: nil,
                                      committedEnd: headerBytes, committedFrames: 0, validFrames: 0)
            }

            var committed: [UInt32: Int] = [:]
            var pending: [UInt32: Int] = [:]
            var databasePages: UInt32?
            var committedEnd = headerBytes
            var committedFrames = 0
            var frames = 0
            var offset = headerBytes
            let frameBytes = frameHeaderBytes + pageSize
            while offset + frameBytes <= raw.count {
                let page = readUInt32(raw, offset)
                let commitSize = readUInt32(raw, offset + 4)
                guard page > 0, readUInt32(raw, offset + 8) == salt1, readUInt32(raw, offset + 12) == salt2 else { break }
                sum = checksum(raw, from: offset, count: 8, seed: sum, bigEndian: bigEndian)
                sum = checksum(raw, from: offset + frameHeaderBytes, count: pageSize, seed: sum, bigEndian: bigEndian)
                guard sum.0 == readUInt32(raw, offset + 16), sum.1 == readUInt32(raw, offset + 20) else { break }
                frames += 1
                pending[page] = offset + frameHeaderBytes
                offset += frameBytes
                if commitSize > 0 {
                    committed.merge(pending) { _, newer in newer }
                    pending.removeAll(keepingCapacity: true)
                    databasePages = commitSize
                    committedEnd = offset
                    committedFrames = frames
                }
            }
            return SQLiteWALIndex(pageSize: pageSize, header: header, pages: committed, databasePages: databasePages,
                                  committedEnd: committedEnd, committedFrames: committedFrames, validFrames: frames)
        }
    }

    /// 主文件的副本 + WAL 里提交过的页，写进 `buffer`（`length` 字节，由 `imageLength` 算好）。
    static func apply(_ index: SQLiteWALIndex?, wal: Data, main: Data, into buffer: UnsafeMutableRawBufferPointer) {
        let copied = min(main.count, buffer.count)
        main.prefix(copied).withUnsafeBytes { source in
            if let base = source.baseAddress, copied > 0 { buffer.baseAddress!.copyMemory(from: base, byteCount: copied) }
        }
        if copied < buffer.count {
            (buffer.baseAddress! + copied).initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count - copied)
        }
        guard let index, let pages = index.databasePages else { return }
        wal.withUnsafeBytes { source in
            for (page, offset) in index.pages where page <= pages {
                let target = Int(page - 1) * index.pageSize
                guard target + index.pageSize <= buffer.count, offset + index.pageSize <= source.count else { continue }
                (buffer.baseAddress! + target).copyMemory(from: source.baseAddress! + offset, byteCount: index.pageSize)
            }
        }
    }

    /// 盖完 WAL 之后的库多长：有提交就按最后一次提交时的页数，否则就是主文件本身。
    static func imageLength(_ index: SQLiteWALIndex?, mainCount: Int) -> Int {
        guard let index, let pages = index.databasePages else { return mainCount }
        return Int(pages) * index.pageSize
    }

    /// SQLite 的 WAL 校验和：按 32 位字两两累加（字节序由头里的 magic 定）。
    private static func checksum(_ raw: UnsafeRawBufferPointer, from offset: Int, count: Int,
                                 seed: (UInt32, UInt32), bigEndian: Bool) -> (UInt32, UInt32) {
        var s0 = seed.0, s1 = seed.1
        var index = offset
        let end = offset + count
        while index < end {
            let a = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)
            let b = raw.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self)
            let x0 = bigEndian ? UInt32(bigEndian: a) : UInt32(littleEndian: a)
            let x1 = bigEndian ? UInt32(bigEndian: b) : UInt32(littleEndian: b)
            s0 = s0 &+ x0 &+ s1
            s1 = s1 &+ x1 &+ s0
            index += 8
        }
        return (s0, s1)
    }

    /// WAL 头与帧头里的整数一律大端。
    static func readUInt32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

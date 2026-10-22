import Foundation

/// 本地暂存文件的「指纹」：修改时间 + 大小 + inode。
///
/// 带 inode 是因为多数编辑器存盘走「写临时文件再 rename 覆盖」，文件换了一个；
/// 时间戳精度不够、大小又没变时（改一个字符），inode 仍能分辨出存过盘。
nonisolated struct LocalFileFingerprint: Equatable, Sendable {
    let modificationDate: Date
    let size: Int64
    let inode: UInt64

    /// 读不到（文件正处在「删旧 → rename 新」的空档里，或被用户删掉）时为 nil。
    static func read(_ url: URL) -> LocalFileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return LocalFileFingerprint(modificationDate: date, size: size, inode: inode)
    }
}

/// 判定「外部应用存了盘、该上传了」。
///
/// 轮询驱动：每次喂一个最新指纹。和上次上传的一样 → 没改动；不一样时**连续两次看到同一个
/// 新指纹**才上传——编辑器分几次 write 落盘、或大文件还在写的时候，上传半截文件比晚一秒
/// 上传糟糕得多。
nonisolated struct ExternalEditChangeDetector: Equatable, Sendable {
    enum Decision: Equatable { case idle, settling, upload(LocalFileFingerprint) }

    /// 远端当前内容对应的本地指纹（下载完成 / 上一次上传成功时的）。
    private(set) var synced: LocalFileFingerprint?
    private var pending: LocalFileFingerprint?
    /// 上传失败或被用户暂缓的那一版：再看到它不自动重传（否则失败会每秒重试一次、
    /// 冲突框会反复弹），直到本地再存一次盘或用户手动重试。
    private(set) var postponed: LocalFileFingerprint?

    init(synced: LocalFileFingerprint?) {
        self.synced = synced
    }

    mutating func observe(_ current: LocalFileFingerprint?) -> Decision {
        guard let current else { return pending == nil ? .idle : .settling }
        guard current != synced else {
            pending = nil
            postponed = nil
            return .idle
        }
        guard current != postponed else { return .idle }
        guard current == pending else {
            pending = current
            return .settling
        }
        return .upload(current)
    }

    /// 上传成功：这个指纹从此就是远端的内容。
    mutating func markSynced(_ fingerprint: LocalFileFingerprint) {
        synced = fingerprint
        pending = nil
        postponed = nil
    }

    /// 上传失败或被用户暂缓。不动 `synced`——远端仍是旧内容，这份改动还算「没同步」。
    mutating func postpone(_ fingerprint: LocalFileFingerprint) {
        pending = nil
        postponed = fingerprint
    }

    /// 手动重试：忘掉暂缓，下一轮（两次轮询后）按新改动上传。
    mutating func clearPostponed() {
        postponed = nil
    }

    /// 本地有没有还没传上去的改动。
    func hasUnsyncedChanges(current: LocalFileFingerprint?) -> Bool {
        guard let current else { return false }
        return current != synced
    }
}

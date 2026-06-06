import Foundation

/// 把拖拽解析结果从 Welcome 传给（已开或将开的）导入向导窗的单例信箱。
@MainActor @Observable final class ImportInbox {
    static let shared = ImportInbox()
    private init() {}

    struct Pending: Equatable {
        let rows: [ImportRow]
        let dir: URL          // 读私钥用（staging 内目录）
        let stagingRoot: URL  // 用完整体删除清理
    }

    private(set) var pending: Pending?
    /// 每次入队 +1。窗口已开时 openWindow 不重跑 onAppear，向导靠 onChange(serial) 消费。
    private(set) var serial: Int = 0

    func enqueue(_ p: Pending) {
        // 替换未被消费的旧 pending 时，先删它的 staging，避免临时目录泄漏。
        if let old = pending {
            try? FileManager.default.removeItem(at: old.stagingRoot)
        }
        pending = p
        serial &+= 1
    }

    func take() -> Pending? {
        let p = pending
        pending = nil
        return p
    }
}

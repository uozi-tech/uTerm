import Foundation
import SwiftData

/// 一条命名的 AI provider 配置。CloudKit 同步（跟 ServerProfile 一致）。
///
/// 重要约束（与 ServerProfile 同）：为兼容 CloudKit，所有存储属性必须有
/// 默认值或为可选，且不能使用 `@Attribute(.unique)`。本模型不含明文 key
/// —— API key 由 `AgentKeychain` 按 `id` 关联存储。
@Model
final class AIProvider {
    var id: UUID = UUID()
    var name: String = ""             // 用户起的名，UI 显示
    var kindRaw: String = ProviderKind.openai.rawValue
    var baseURL: String = ""          // root URL（不含路径段）；空时 client fallback 到 kind 预置
    var model: String = ""            // model id；自由文本，UI 端有预置下拉
    var sortOrder: Int = 0            // 列表排序
    var createdAt: Date = Date()

    /// CloudKit 要求的无参构造。代码侧通常用下方 convenience init。
    init() {}

    /// 业务代码与测试用的便利构造。
    convenience init(name: String,
                     kind: ProviderKind,
                     baseURL: String,
                     model: String,
                     sortOrder: Int = 0,
                     id: UUID = UUID(),
                     createdAt: Date = Date()) {
        self.init()
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.baseURL = baseURL
        self.model = model
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    /// 便利读取——kindRaw 失效时 fallback openai（保守，不掉链子）。
    var kind: ProviderKind {
        ProviderKind(rawValue: kindRaw) ?? .openai
    }
}

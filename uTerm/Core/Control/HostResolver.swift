import Foundation

/// 主机名 / UUID → `ServerProfile` 的三级解析，抽成纯函数以便单测。
///
/// 规则（照抄 uTable 的连接解析）：
/// 1. 字符串能解析成 UUID 且命中某条档案 → 直达；
/// 2. 名字**精确**匹配 → 唯一即命中；
/// 3. 名字**忽略大小写**匹配 → 唯一即命中；
/// 4. 名字**前缀**匹配 → 唯一即命中。
///
/// 任何一级命中多条都是 `host_ambiguous`，并把候选（带 UUID）回给 CLI ——
/// CloudKit 同步下同名主机是常态，技能文档教模型改用 UUID 重试。
///
/// Wave 1 待填。实现约定：入参是**已摘取的轻量元组数组**（id + name），
/// 不要直接吃 `ServerProfile`（`@Model` 不是 Sendable，也不便造测试夹具）；
/// `ControlHandler+Hosts.resolveHost` 负责取数据、翻错。
nonisolated enum HostResolver {
}

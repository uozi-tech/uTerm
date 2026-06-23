import Foundation
import SwiftData

/// SSH 端口转发类型。以原始字符串持久化（SwiftData+CloudKit 对枚举以 String rawValue 最稳妥）。
/// `Sendable` —— 简单值枚举，可跨 actor 传递（snapshot 内含它）。
enum ForwardKind: String, CaseIterable, Sendable {
    case local
    case remote
    case dynamic

    /// ssh 命令行 flag。
    nonisolated var flag: String {
        switch self {
        case .local:   return "-L"
        case .remote:  return "-R"
        case .dynamic: return "-D"
        }
    }

    /// 紧凑标签（徽章 / 分段控件）。
    nonisolated var shortLabel: String {
        switch self {
        case .local:   return "本地"
        case .remote:  return "远程"
        case .dynamic: return "动态"
        }
    }

    /// 完整标签（编辑器分段选项）。
    nonisolated var label: String {
        switch self {
        case .local:   return "本地转发"
        case .remote:  return "远程转发"
        case .dynamic: return "动态转发"
        }
    }

    /// 类型说明（编辑器分段下方的描述行）。
    nonisolated var desc: String {
        switch self {
        case .local:   return "把本地端口的流量经 SSH 转发到远端可达的目标地址。"
        case .remote:  return "把远端服务器端口的流量经 SSH 转发回本地可达的目标地址。"
        case .dynamic: return "在本地开一个 SOCKS5 代理，由客户端按需选择目标。"
        }
    }

    /// 监听侧字段标题。local/dynamic 监听本地，remote 监听远端。
    nonisolated var srcLabel: String {
        switch self {
        case .local, .dynamic: return "本地监听"
        case .remote:          return "远端监听"
        }
    }

    /// 目标侧字段标题。dynamic 无固定目标 → nil。
    nonisolated var dstLabel: String? {
        switch self {
        case .local:   return "目标地址"
        case .remote:  return "本地目标"
        case .dynamic: return nil
        }
    }

    /// 流向箭头是否反转（remote 把远端 → 本地）。
    nonisolated var reverse: Bool { self == .remote }

    /// 是否需要目标 host/port（dynamic 由 SOCKS 协议动态决定 → false）。
    nonisolated var needsDest: Bool { self != .dynamic }
}

/// 一条 SSH 端口转发规则。只持久化**配置**；运行时状态（status/error）不入库。
/// 经 SwiftData + CloudKit 跨设备同步。
///
/// CloudKit 约束（与 `ServerProfile`/`ServerGroup` 一致）：所有存储属性须有默认值或可选，
/// **禁** `@Attribute(.unique)`，枚举存 String rawValue。规则↔主机用外键 `serverID`
/// （非 `@Relationship`，仿 `ServerProfile.keyID`）—— 删主机时手动清理孤儿规则。
@Model
final class ForwardingRule {
    var id: UUID = UUID()
    /// 外键 → `ServerProfile.id`。
    var serverID: UUID = UUID()
    var name: String = ""
    /// `ForwardKind` 的 rawValue。通过 `kind` 计算属性读写。
    var typeRaw: String = ForwardKind.local.rawValue
    var listenHost: String = "127.0.0.1"
    var listenPort: Int = 0
    /// dynamic 为 nil。
    var destHost: String? = nil
    /// 调用方约定：dynamic 时传 0（无实际意义）。
    var destPort: Int = 0
    /// 目标的人类可读别名（可空，仅展示）。
    var destLabel: String? = nil
    /// **连接级**自启：连到该主机（打开端口转发窗口）时自动拉起本规则。
    var autostart: Bool = false
    /// **应用级**自启：uTerm 启动时自动建立本隧道（全局端口转发面板的「随 uTerm 启动 / 自启」）。
    /// 与 `autostart` 互不干扰 —— 一个是「连到主机时」，一个是「开 App 时」（见全局端口转发 spec §5）。
    /// CloudKit 约束：须有默认值（旧记录迁移后为 false）。
    var launchAtAppStart: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// CloudKit 要求的零参 init（所有属性已有默认值）。
    init() {}

    var kind: ForwardKind {
        get { ForwardKind(rawValue: typeRaw) ?? .local }
        set { typeRaw = newValue.rawValue }
    }

    /// 设满全部存储字段的便利构造器。
    convenience init(serverID: UUID, name: String, kind: ForwardKind,
                     listenHost: String, listenPort: Int,
                     destHost: String?, destPort: Int,
                     destLabel: String?, autostart: Bool, sortOrder: Int,
                     launchAtAppStart: Bool = false) {
        self.init()
        self.serverID = serverID
        self.name = name
        self.typeRaw = kind.rawValue
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destHost = destHost
        self.destPort = destPort
        self.destLabel = destLabel
        self.autostart = autostart
        self.sortOrder = sortOrder
        self.launchAtAppStart = launchAtAppStart
    }

    /// 不可变 `Sendable` 快照 —— 把规则配置带出 `@MainActor`/SwiftData 上下文
    /// 进纯函数（PortConflictChecker）或 actor（ForwardingSession），避免传 `@Model`。
    var snapshot: ForwardingRuleSnapshot {
        ForwardingRuleSnapshot(id: id, serverID: serverID, name: name, kind: kind,
                               listenHost: listenHost, listenPort: listenPort,
                               destHost: destHost, destPort: destPort, autostart: autostart)
    }
}

/// `ForwardingRule` 的不可变值快照。`Sendable` + `nonisolated` 友好（无 @Model / @MainActor 依赖）。
struct ForwardingRuleSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let serverID: UUID
    let name: String
    let kind: ForwardKind
    let listenHost: String
    let listenPort: Int
    let destHost: String?
    let destPort: Int
    let autostart: Bool
}

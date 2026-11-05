import Foundation
import SwiftData

/// 新建 / 编辑 / 复制主机表单的草稿，两端共用（macOS `ServerFormView`、iOS `HostFormSheet`）。
/// 视图只持有 `@State var draft` 与纯 UI 状态，字段校验与写回都在这里。
///
/// 字段保存的是表单里的**原始输入**（视图直接绑定）；比较与写回用规范化后的值
/// （去首尾空白、端口转数字、非私钥认证时不带 `keyID`）。
struct HostDraft {
    var name = ""
    var host = ""
    var port = "22"
    var username = ""
    var group = ""
    var auth: AuthMethod
    var password = ""
    var keyID: UUID?
    var sftpOnly = false
    /// 跳板机开关 + 所选跳板机。只有 macOS 表单编辑它们；iOS 不碰，保存时也就不会改动主机的跳板机。
    var useJumpHost = false
    var jumpHostID: UUID?

    /// 新建空表单。两端默认的认证方式不同（iOS 密码、macOS 私钥），由调用方给。
    init(auth: AuthMethod = .password) {
        self.auth = auth
    }

    /// 用现有主机预填（编辑）。密码从钥匙串读，读不到就留空。
    init(from profile: ServerProfile, keychain: KeychainStore = KeychainStore()) {
        auth = profile.authMethod
        name = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        group = profile.group ?? ""
        keyID = profile.keyID
        sftpOnly = profile.sftpOnly
        password = (try? keychain.load(profileID: profile.id, kind: .password)) ?? ""
        if let jump = profile.jumpHost {
            useJumpHost = true
            jumpHostID = jump.id
        }
    }

    /// 用源主机预填、存为**新**主机（复制）：名字加「副本」后缀，避免与源同名混淆。
    init(duplicating profile: ServerProfile, keychain: KeychainStore = KeychainStore()) {
        self.init(from: profile, keychain: keychain)
        name = Self.duplicateName(of: profile.name)
    }

    /// 复制时的默认新名：`原名 副本`（原名为空则只 "副本"）。
    static func duplicateName(of original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "副本" : "\(trimmed) 副本"
    }

    // MARK: - 规范化

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedGroup: String { group.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 端口数值：留空按 22。非法值由 `portError` 拦在保存之前。
    var portValue: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? 22 }
    /// 实际生效的密钥：只有私钥认证才带。
    var effectiveKeyID: UUID? { auth == .privateKey ? keyID : nil }
    /// 实际生效的跳板机：开关关着就没有。
    var effectiveJumpHostID: UUID? { useJumpHost ? jumpHostID : nil }

    // MARK: - 校验

    /// 端口 inline 校验：留空（= 22）或 1–65535 的整数。
    var portError: String? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let p = Int(trimmed) else { return "端口必须是数字" }
        guard (1...65535).contains(p) else { return "端口需在 1–65535 之间" }
        return nil
    }

    /// 能否保存：名称 / 主机 / 用户名必填、端口合法、私钥认证须选密钥、开了跳板机须选一台。
    var isValid: Bool {
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !trimmedUsername.isEmpty,
              portError == nil else { return false }
        if auth == .privateKey, keyID == nil { return false }
        if useJumpHost, jumpHostID == nil { return false }
        return true
    }

    // MARK: - 保存

    /// 写回 `target`（nil = 新建并插入），返回保存的主机；`target` 在表单打开期间被同步删掉时
    /// 什么都不写，返回 nil。
    ///
    /// 编辑时**只写与 `original` 相比真正改过的字段**：表单开着期间 CloudKit / 局域网同步
    /// 可能改了这台主机的分组、密钥等，整份写回会悄悄把它们改回旧值。新建时没有基准，全部写。
    ///
    /// - 分组非空时 `GroupStore.ensure` 补建 `ServerGroup` 行；
    /// - 密码认证：密码非空且改过才写钥匙串（钥匙串 save 是 delete + add，并会经 iCloud 钥匙串广播）；
    /// - 切到私钥认证：删掉这台主机按 `profile.id` 存的旧密码。
    @discardableResult
    func save(
        original: HostDraft?,
        to target: ServerProfile?,
        context: ModelContext,
        keychain: KeychainStore = KeychainStore()
    ) -> ServerProfile? {
        if let target, target.isDeleted || target.modelContext == nil { return nil }
        let profile = target ?? ServerProfile()
        let old = target == nil ? nil : original

        if trimmedName != old?.trimmedName { profile.name = trimmedName }
        if trimmedHost != old?.trimmedHost { profile.host = trimmedHost }
        if portValue != old?.portValue { profile.port = portValue }
        if trimmedUsername != old?.trimmedUsername { profile.username = trimmedUsername }
        if auth != old?.auth { profile.authMethod = auth }
        if effectiveKeyID != old?.effectiveKeyID || auth != old?.auth { profile.keyID = effectiveKeyID }
        if trimmedGroup != old?.trimmedGroup { profile.group = trimmedGroup.isEmpty ? nil : trimmedGroup }
        if sftpOnly != old?.sftpOnly { profile.sftpOnly = sftpOnly }
        if effectiveJumpHostID != old?.effectiveJumpHostID {
            profile.jumpHost = Self.jumpHost(id: effectiveJumpHostID, excluding: profile.id, in: context)
        }
        if !trimmedGroup.isEmpty {
            GroupStore(context: context).ensure(name: trimmedGroup)
        }

        if target == nil {
            profile.sortOrder = ServerProfileStore(context: context).nextSortOrder()
            context.insert(profile)
        }
        try? context.save()

        switch auth {
        case .password:
            if !password.isEmpty, password != old?.password {
                try? keychain.save(password, profileID: profile.id, kind: .password)
            }
        case .privateKey:
            // 私钥正文由密钥库承载；切过来时清掉这台主机可能存在的旧密码。
            if old?.auth != .privateKey {
                try? keychain.delete(profileID: profile.id, kind: .password)
            }
        }
        return profile
    }

    private static func jumpHost(id: UUID?, excluding selfID: UUID, in context: ModelContext) -> ServerProfile? {
        guard let id, id != selfID else { return nil }
        let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}

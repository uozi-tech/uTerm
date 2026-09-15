import UDesignKit
import SwiftUI
import SwiftData
import UIKit

/// 设置标签（设计稿 `m-more` 的 `MoreBody`）：品牌卡 + 动作 / 外观 / 终端 / 安全 / 关于。
/// 保持五标签结构不变——设计稿「更多」分区在此承载（命令面板 / 密钥 / 分组 / 指纹）。
struct SettingsScreen: View {
    @AppStorage("appearancePreference")
    private var appearanceRaw: String = AppearancePreference.system.rawValue
    /// 应用锁开关，与启动时读的键同源（缺键视作关）。
    @AppStorage("requireAuthAtLaunch") private var appLockOn = false
    @State private var lockUnavailable = false
    @State private var showSyncDiag = false
    @Environment(\.mAccent) private var accent
    @Environment(MobileStore.self) private var store
    /// CloudKit 同步实时状态（MobileApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync

    @Environment(\.modelContext) private var context

    /// 五个徽标计数。
    ///
    /// 改前是五个**无谓词、无 `fetchLimit`** 的 `@Query` —— 一进设置页就把
    /// `ServerProfile` / `SSHKey` / `ServerGroup` / `KnownHost` /
    /// `ForwardingRule` 五张表整表取出来物化成模型对象，只为在行尾显示
    /// 五个数字（连过几百台机器的库里 `KnownHost` 本身就上千行）。
    /// 现在走 `context.fetchCount`：SQL 层的 `COUNT(*)`，不物化任何对象。
    ///
    /// 代价是失去 `@Query` 的自动订阅，所以在 `onAppear`（切进标签 / 从
    /// 二级页返回）和 `ModelContext.didSave`（本机任何一次写）两处刷新。
    @State private var counts = SettingsCounts()

    private struct SettingsCounts {
        var hosts = 0
        var keys = 0
        var groups = 0
        var knownHosts = 0
        var forwards = 0
    }

    private func refreshCounts() {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        counts = SettingsCounts(hosts: count(ServerProfile.self),
                                keys: count(SSHKey.self),
                                groups: count(ServerGroup.self),
                                knownHosts: count(KnownHost.self),
                                forwards: count(ForwardingRule.self))
    }

    private var appearance: Binding<AppearancePreference> {
        Binding(get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            MScreen(title: "设置") {
                VStack(spacing: 0) {
                    profileCard
                    actionsGroup
                    appearanceGroup
                    terminalGroup
                    securityGroup
                    LANSyncSettingsSection()
                    aboutGroup
                    copyrightFooter
                }
            }
            .navigationBarHidden(true)
            .onAppear(perform: refreshCounts)
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                refreshCounts()
            }
            .alert("无法开启应用锁", isPresented: $lockUnavailable) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请先在系统「设置」里启用 Face ID / 触控 ID 或设置锁屏密码，再开启应用锁。")
            }
            .sheet(isPresented: $showSyncDiag) {
                MSyncDiagSheet(sync: sync)
            }
        }
    }

    /// 当前机器的生物识别类型（文案 + 图标），用于应用锁开关行。
    private var biometry: (title: String, icon: String) { MobileBiometry.describe() }

    /// 应用锁开关：开启前先验证一次（确认设备可用 + 取得用户授权），成功才真正打开，
    /// 避免一拨开关就把下次启动锁死却无从解锁。关闭则直接生效。
    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { appLockOn },
            set: { wantOn in
                guard wantOn else { appLockOn = false; return }
                Task {
                    let outcome = await MobileBiometry.confirmEnable()
                    if case .success = outcome {
                        appLockOn = true
                    } else {
                        appLockOn = false
                        if case .unavailable = outcome { lockUnavailable = true }
                    }
                }
            })
    }

    // 版权（年份自动取当年，与 macOS「关于」页一致）
    private var copyrightFooter: some View {
        Text(copyrightString)
            .font(M.sans(11))
            .foregroundStyle(M.text4)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 24)
    }

    private var copyrightString: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) 柚子星云科技（深圳）有限公司"
    }

    // 品牌卡
    private var profileCard: some View {
        HStack(spacing: 14) {
            ULogo(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("uTerm").font(M.sans(17, weight: .semibold)).foregroundStyle(M.text)
                Text("\(counts.hosts) 台主机 · \(counts.keys) 个密钥 · \(liveSyncStatus)")
                    .font(M.mono(12.5)).foregroundStyle(M.text3)
            }
            Spacer()
        }
        .padding(16)
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
    }

    // 动作（快捷命令已升为底部「命令」主标签，此处仅留命令面板）
    @ViewBuilder private var actionsGroup: some View {
        MInsetGroup(header: "动作") {
            MInsetRow(icon: "cmd", label: "命令面板", sub: "搜索主机、命令、文件",
                      chevron: true, last: true, onTap: { store.showPalette = true })
        }
    }

    // 外观：主题 + 强调色
    private var appearanceGroup: some View {
        MInsetGroup(header: "外观") {
            VStack(alignment: .leading, spacing: 9) {
                Text("主题").font(M.sans(14)).foregroundStyle(M.text2)
                Picker("主题", selection: appearance) {
                    ForEach(AppearancePreference.allCases) { p in Text(p.localizedLabel).tag(p) }
                }
                .pickerStyle(.segmented)
            }
            .padding(14)
            .overlay(alignment: .bottom) { MRowDivider() }

            VStack(alignment: .leading, spacing: 11) {
                Text("强调色").font(M.sans(14)).foregroundStyle(M.text2)
                AccentPickerRow()
            }
            .padding(14)
        }
    }

    // 终端（iOS 端为固定外观，作信息展示）
    private var terminalGroup: some View {
        MInsetGroup(header: "终端") {
            MInsetRow(label: "字体", value: "系统等宽", valueMono: true)
            MInsetRow(label: "字号", value: "13 pt")
            MInsetRow(label: "光标", value: "稳定块", last: true)
        }
    }

    // 安全：应用锁 / 密钥 / 分组 / 指纹 / 端口转发
    private var securityGroup: some View {
        MInsetGroup(header: "安全") {
            MInsetRow(icon: biometry.icon, label: "\(biometry.title) 解锁",
                      sub: "回到 uTerm 时需验证身份",
                      trailing: AnyView(MSwitch(on: appLockBinding)))
            NavigationLink { KeysScreen() } label: {
                MInsetRow(icon: "key", label: "SSH 密钥", value: "\(counts.keys)", chevron: true)
            }.buttonStyle(MRowStyle())
            NavigationLink { GroupsScreen() } label: {
                MInsetRow(icon: "tag", label: "主机分组", value: "\(counts.groups)", chevron: true)
            }.buttonStyle(MRowStyle())
            NavigationLink { FingerprintsView() } label: {
                MInsetRow(icon: "shield", label: "已知主机指纹", value: "\(counts.knownHosts)", chevron: true)
            }.buttonStyle(MRowStyle())
            // 移动端没有端口转发的管理页（转发是 macOS 端的能力），这一行只报数。
            // 改前带着 `chevron: true` 却没有 `onTap` —— 看着可点、点了没反应。
            MInsetRow(icon: "forward", label: "端口转发规则", value: "\(counts.forwards)",
                      last: true)
        }
    }

    // 关于
    private var aboutGroup: some View {
        MInsetGroup(header: "关于") {
            MInsetRow(icon: "icloud", label: "同步诊断", sub: syncDiagSub,
                      chevron: true, onTap: { showSyncDiag = true })
            MInsetRow(label: "版本", value: appVersion, last: true)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// 如实的同步状态：本地存储（CloudKit 未建成）/ 未登录 iCloud / iCloud 同步。
    private var syncStatus: String {
        guard MobileModelContainer.usingCloudKit else { return "本地存储" }
        return FileManager.default.ubiquityIdentityToken != nil ? "iCloud 同步" : "未登录 iCloud"
    }

    /// 在 `syncStatus`（本地 / 未登录 / iCloud）基础上叠 monitor.phase 的进行态。
    private var liveSyncStatus: String {
        guard MobileModelContainer.usingCloudKit,
              FileManager.default.ubiquityIdentityToken != nil else { return syncStatus }
        switch sync.phase {
        case .setup:     return "连接中…"
        case .importing: return "下载中…"
        case .exporting: return "上传中…"
        case .error:     return "同步出错"
        case .idle:      return "iCloud 同步"
        }
    }

    /// 「同步诊断」行副标题：登录后显示最近事件数，否则提示基础状态。
    private var syncDiagSub: String {
        guard MobileModelContainer.usingCloudKit,
              FileManager.default.ubiquityIdentityToken != nil
        else { return syncStatus }
        return sync.lastError ?? "查看最近同步事件 · 复制日志"
    }
}

/// 同步诊断弹窗：展示 CloudKit 最近事件（环形缓冲，新→旧）+ 复制日志。
/// iOS 无 Console，故在 app 内提供——对照 macOS「高级 › 显示日志」的 Console 入口。
private struct MSyncDiagSheet: View {
    let sync: CloudKitSyncMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("同步诊断").font(M.sans(17, weight: .semibold)).foregroundStyle(M.text)
                Spacer()
                Button("完成") { dismiss() }
                    .font(M.sans(15)).foregroundStyle(M.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(M.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if sync.recentEvents.isEmpty {
                        Text("暂无同步事件。保持 app 前台、已登录 iCloud 后，setup / import / export 事件会出现在这里。")
                            .font(M.sans(13)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    } else {
                        ForEach(sync.recentEvents.reversed()) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Text(MFormat.clock(e.date))
                                    .font(M.mono(11)).foregroundStyle(M.text4)
                                    .frame(width: 62, alignment: .leading)
                                Text(e.text).font(M.mono(12)).foregroundStyle(M.text2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            MBtn(title: "复制日志", kind: .secondary, full: true, height: 48) {
                UIPasteboard.general.string = sync.exportText()
            }
            .padding(16)
        }
        .presentationBackground(M.panel)
        .presentationDetents([.medium, .large])
    }

    // 共享格式化器（`MFormat`）：改前每条事件行都现建一个 `DateFormatter`。
}

/// 强调色选择（5 色，写 AccentState，全局即时重染）。
struct AccentPickerRow: View {
    @State private var selected: AccentColor = AccentState.shared.selected

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AccentColor.allCases) { color in
                let c = color.base(dark: true).color()
                Circle().fill(c)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(.white, lineWidth: selected == color ? 2.5 : 0))
                    .overlay(Circle().stroke(M.border, lineWidth: 1))
                    .scaleEffect(selected == color ? 1.08 : 1)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) {
                            selected = color
                            AccentState.shared.selected = color
                        }
                    }
            }
            Spacer()
        }
    }
}

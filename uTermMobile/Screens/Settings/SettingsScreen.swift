import UDesignKit
import SwiftUI
import SwiftData
import UIKit
import Combine

/// 设置标签（设计稿 `m-more` 的 `MoreBody`）：品牌卡 + 动作 / 外观 / 终端 / 安全 / 关于。
/// 保持五标签结构不变——设计稿「更多」分区在此承载（命令面板 / 密钥 / 分组 / 指纹）。
struct SettingsScreen: View {
    @AppStorage("appearancePreference")
    private var appearanceRaw: String = AppearancePreference.system.rawValue
    /// 应用锁开关，与启动时读的键同源（缺键视作关）。
    @AppStorage(AppLockPreference.key) private var appLockOn = AppLockPreference.defaultValue
    /// 会话保留窗口（天）。与 macOS 共用 key，可经 iCloud KVS / 局域网同步。
    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays = ChatHistoryStore.defaultRetentionDays
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
        var providers = 0
    }

    private func refreshCounts() {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        counts = SettingsCounts(hosts: count(ServerProfile.self),
                                keys: count(SSHKey.self),
                                groups: count(ServerGroup.self),
                                knownHosts: count(KnownHost.self),
                                forwards: count(ForwardingRule.self),
                                providers: count(AIProvider.self))
    }

    private var appearance: Binding<AppearancePreference> {
        Binding(get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            MScreen(title: "设置", embedsNavigationStack: false, pinsHeader: true) {
                VStack(spacing: 0) {
                    profileCard
                    actionsGroup
                    agentGroup
                    appearanceGroup
                    terminalGroup
                    securityGroup
                    historyGroup
                    LANSyncSettingsSection()
                    aboutGroup
                    #if DEBUG
                    debugGroup
                    #endif
                    copyrightFooter
                }
            }
            .onAppear(perform: refreshCounts)
            // 局域网覆盖在后台上下文里保存，`didSave` 会在那条线程上发出；回主线程再刷新。
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                .receive(on: DispatchQueue.main)) { _ in
                refreshCounts()
            }
            .alert("无法开启应用锁", isPresented: $lockUnavailable) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请先在系统「设置」里启用 Face ID / 触控 ID 或设置锁屏密码，再开启应用锁。")
            }
            .sheet(isPresented: $showSyncDiag) {
                MSyncDiagSheet(sync: sync).mSheetContentMargins()
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
                    let outcome = await AppLockModel.confirmEnable()
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
                Text("\(counts.hosts) 台主机 · \(counts.keys) 个密钥 · \(syncStatus.label)")
                    .font(M.mono(12.5)).foregroundStyle(M.text3)
            }
            Spacer()
        }
        .padding(16)
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
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

    // AI：模型服务（对齐 macOS 设置的「模型服务」页）
    private var agentGroup: some View {
        MInsetGroup(header: "AI", footer: "Agent 用到的模型服务。服务列表经 iCloud 与 Mac 同步，API Key 经 iCloud 钥匙串同步。") {
            NavigationLink { ProvidersScreen() } label: {
                MInsetRow(icon: "spark", label: "模型服务",
                          sub: counts.providers == 0 ? "尚未配置" : nil,
                          value: counts.providers == 0 ? nil : "\(counts.providers)",
                          chevron: true, last: true)
            }.buttonStyle(MRowStyle())
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
            // 移动端终端字号随可用宽度自适应（9–13pt，见 TerminalSessionBody.adaptiveFontSize），
            // 不是固定 13pt——iPhone Duo 外屏 / 分屏更小、展开 / iPad 更大。
            MInsetRow(label: "字号", value: "随宽度自适应")
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

    // 历史
    /// 保留窗口用预设菜单而不是数字输入：手机上敲数字既要弹键盘又要校验，
    /// 而这本来就是个粗粒度选择。0 = 不清理。
    private static let retentionOptions: [(Int, String)] = [
        (0, "不清理"), (30, "30 天"), (90, "90 天"), (180, "180 天"), (365, "365 天"),
    ]

    private var historyGroup: some View {
        MInsetGroup(header: "历史", footer: chatRetentionFooter) {
            MInsetRow(icon: "clock", label: "会话保留", last: true,
                      trailing: AnyView(
                          MMenu {
                              ForEach(Self.retentionOptions, id: \.0) { option in
                                  Button(option.1) { chatRetentionDays = option.0 }
                              }
                          } label: {
                              HStack(spacing: 4) {
                                  Text(chatRetentionLabel)
                                      .font(M.sans(15)).foregroundStyle(M.text2)
                                  MIcon(name: "chev-down", size: 11, color: M.text4)
                              }
                          }))
        }
    }

    private var chatRetentionLabel: String {
        Self.retentionOptions.first { $0.0 == chatRetentionDays }?.1
            ?? "\(chatRetentionDays) 天"
    }

    private var chatRetentionFooter: String {
        chatRetentionDays > 0
            ? "超过该天数未更新的 AI 会话会在启动时清理，连同其中的消息。该设置与 Mac 同步。"
            : "选“不清理”后会话会一直累积，并占用 iCloud 配额。"
    }

    // 关于
    #if DEBUG
    @AppStorage(MLayoutDiagnostics.key) private var layoutDiagnostics = false

    /// 仅 Debug 构建：布局诊断浮层开关（见 MLayoutDiagnostics）。
    private var debugGroup: some View {
        MInsetGroup(header: "调试", footer: "在屏幕左下角显示安全区、状态栏保留区与终端视图几何，供截图排查布局。仅 Debug 构建可见。") {
            MInsetRow(label: "布局诊断", last: true,
                      trailing: AnyView(MSwitch(on: $layoutDiagnostics)))
        }
    }
    #endif

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

    /// 如实的同步状态（两端共用 `CloudKitSyncStatus`）：本地存储（CloudKit 未建成）/
    /// 未登录 iCloud / 叠上 monitor.phase 的进行态 / 已同步 · 等待同步。
    private var syncStatus: CloudKitSyncStatus {
        sync.status(loggedIn: FileManager.default.ubiquityIdentityToken != nil,
                    usingCloudKit: MobileModelContainer.usingCloudKit)
    }

    /// 「同步诊断」行副标题：登录后显示最近错误或入口说明，否则提示基础状态。
    private var syncDiagSub: String {
        let status = syncStatus
        guard status.isCloudActive else { return status.label }
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
            // 头部与底部按钮不在滚动内容里，`mSheetContentMargins` 管不到，直接按弹窗边距排
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.top, 18).padding(.bottom, 14)
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
                                Text(UFormat.time(e.date))
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
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.vertical, 16)
        }
        .presentationBackground(M.panel)
        .presentationDetents([.medium, .large])
    }

}

/// 强调色选择（5 色，写 AccentState，全局即时重染）。
struct AccentPickerRow: View {
    @State private var selected: AccentColor = AccentState.shared.selected

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AccentColor.allCases) { color in
                let c = color.base(dark: true).color()
                let on = selected == color
                Circle().fill(c)
                    .frame(width: 30, height: 30)
                    // 选中环：外圈一道正文色描边，中间隔开 3pt 卡片底。旧版是贴边白环，
                    // 日间白卡上完全看不出选中了哪一个。
                    .padding(3)
                    .overlay(Circle().strokeBorder(on ? M.text : .clear, lineWidth: 2))
                    .frame(width: M.minTarget, height: M.minTarget)   // 命中区 44pt
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) {
                            selected = color
                            AccentState.shared.selected = color
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(color.label))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.leading, -7)   // 让第一个色块的视觉左缘与上方「强调色」文字对齐
    }
}

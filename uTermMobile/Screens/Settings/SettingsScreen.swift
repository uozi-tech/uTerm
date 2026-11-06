import UDesignKit
import SwiftUI
import SwiftData
import Combine

/// 设置标签（设计稿 `m-more` 的 `MoreBody`）：品牌卡 + 动作，再按 `sectionOrder` 排各分区
/// （与 macOS 设置窗同一份 `SettingsSection` 信息架构）+ 版权。各分组在 `Sections/` 下；
/// 共享的状态与文案在 `uTerm/Features/Settings/Model/`。
struct SettingsScreen: View {
    @State private var appLock = AppLockToggleModel()
    @State private var showSyncDiag = false
    @Environment(MobileStore.self) private var store
    /// CloudKit 同步实时状态（MobileApp 注入；订阅 NSPersistentCloudKitContainer 事件）。
    @Environment(CloudKitSyncMonitor.self) private var sync

    @Environment(\.modelContext) private var context

    /// 根页的分区顺序（品牌卡与「动作」之后）。iOS 可用的每个分区恰好出现一次（`MobileSettingsSectionsTests` 钉住）。
    static let sectionOrder: [SettingsSection] = [
        .appearance, .terminal, .providers, .connection, .security, .sync, .remote, .diagnostics, .about,
    ]

    /// 行尾的数量徽标。走 `fetchCount` 不物化对象（见 `LibraryCounts`），代价是没有自动订阅，
    /// 所以在 `onAppear`（切进标签 / 从二级页返回）和 `ModelContext.didSave`（本机任何一次写）两处刷新。
    @State private var counts = LibraryCounts()

    private func refreshCounts() {
        counts = LibraryCounts.fetch(in: context)
    }

    var body: some View {
        NavigationStack {
            MScreen(title: "设置", embedsNavigationStack: false, pinsHeader: true) {
                VStack(spacing: 0) {
                    profileCard
                    actionsGroup
                    ForEach(Self.sectionOrder) { section in
                        sectionView(section)
                    }
                    copyrightFooter
                }
            }
            .onAppear(perform: refreshCounts)
            // 局域网覆盖在后台上下文里保存，`didSave` 会在那条线程上发出；回主线程再刷新。
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                .receive(on: DispatchQueue.main)) { _ in
                refreshCounts()
            }
            .alert(AppLockToggleModel.unavailableTitle, isPresented: $appLock.unavailableAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(AppLockToggleModel.unavailableMessage)
            }
            .sheet(isPresented: $showSyncDiag) {
                SyncDiagnosticsSheet(sync: sync).mSheetContentMargins()
            }
        }
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

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:  SettingsAppearanceSection()
        case .terminal:    SettingsTerminalSection()
        case .providers:   SettingsProvidersSection(providerCount: counts.providers)
        case .connection:  SettingsConnectionSection()
        case .security:    SettingsSecuritySection(counts: counts, appLock: appLock)
        case .sync:        SettingsSyncSection(cloudStatus: syncStatus,
                                               diagnosticsSubtitle: syncDiagSub,
                                               showDiagnostics: { showSyncDiag = true })
        case .remote:      SettingsRemoteSection()
        case .diagnostics: SettingsDiagnosticsSection()
        case .about:       SettingsAboutSection()
        case .general, .cli:
            // 只有 macOS 有（启动 / 更新、本机命令行接口）。
            EmptyView()
        }
    }

    /// 如实的同步状态（两端共用 `CloudKitSyncStatus`）：本地存储（CloudKit 未建成）/
    /// 未登录 iCloud / 叠上 monitor.phase 的进行态 / 已同步 · 等待同步。
    private var syncStatus: CloudKitSyncStatus {
        sync.status(loggedIn: FileManager.default.ubiquityIdentityToken != nil,
                    usingCloudKit: MobileModelContainer.usingCloudKit)
    }

    /// 「同步诊断」行副标题：登录后显示最近错误或入口说明，否则提示基础状态。
    private var syncDiagSub: String {
        SyncStatusPresentation.diagnosticsSubtitle(status: syncStatus, lastError: sync.lastError)
    }
}

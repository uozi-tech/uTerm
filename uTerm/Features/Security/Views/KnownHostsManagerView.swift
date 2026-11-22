import UDesignKit
import SwiftUI
import SwiftData

/// 已知主机指纹窗口（设置 · 安全 → 「已知主机指纹」）。列出 TOFU 信任过的主机密钥，
/// 可按地址 / 指纹搜索，逐条删除（二次确认）。删掉后下次连接该主机会重新要求确认指纹。
///
/// 展示规则、文案与删除都和 iOS `FingerprintsView` 共用（`KnownHostDisplay` / `KnownHostCopy` /
/// `KnownHostLibrary`）；这里只画 mac 的单栏列表。独立 `Window`，外观随全局主题。
struct KnownHostsManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\KnownHost.firstTrustedAt, order: .reverse)]) private var hosts: [KnownHost]

    @State private var query = ""
    @State private var pendingDelete: KnownHost?

    private var filtered: [KnownHost] { hosts.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            KnownHostsTitleBar()
            if hosts.isEmpty {
                emptyState
            } else {
                searchBar
                list
                Rectangle().fill(UD.border).frame(height: 1)
                footer
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        // 自绘扁平 chrome（同密钥 / 分组管理窗口）：透明系统标题栏 + 让位红绿灯的自绘标题栏。
        // 内容区与设置窗同一套：窗底上一张描边卡片列表（见 SettingsPrimitives）。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: String(localized: "已知主机指纹")))
        .overlay { deleteConfirmOverlay }
    }

    // MARK: - 搜索 / 列表

    private var searchBar: some View {
        UDSearchField(text: $query, placeholder: String(localized: "按地址或指纹搜索"), showsHotkeyChip: false)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            // 搜索条与列表同底色，底部 1pt 线分隔。
            .background(UD.bg)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    @ViewBuilder
    private var list: some View {
        let rows = filtered
        if rows.isEmpty {
            VStack {
                SettingsEmptyRow(symbol: "magnifyingglass", text: String(localized: "没有匹配「\(query)」的主机"))
                    .settingsCard()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // 懒加载：连过几百台机器的库里 KnownHost 有上千行。分组卡片的自动分隔线要先拆子视图，
                // 不懒，所以这里照同样的样式手画：卡片底 + 行间缩进到文字起点的 1pt 线。
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, host in
                        if index > 0 {
                            Rectangle().fill(SettingsLine.row).frame(height: 1)
                                .padding(.leading, SettingsMetrics.listTextInset)
                        }
                        KnownHostRow(host: host, onDelete: { pendingDelete = host })
                    }
                }
                .settingsCard()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(hosts.count) 台已知主机")
            Spacer()
            Text("首次连接或主机密钥变化时，uTerm 会要求你确认指纹后才信任。")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(UD.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(UD.text4)
            Text(KnownHostCopy.emptyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text2)
            Text(KnownHostCopy.emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 删除确认

    @ViewBuilder
    private var deleteConfirmOverlay: some View {
        if let host = pendingDelete {
            KnownHostDeleteConfirm(
                address: host.displayAddress,
                onCancel: { pendingDelete = nil },
                onConfirm: {
                    KnownHostLibrary.delete(host, in: modelContext)
                    pendingDelete = nil
                })
        }
    }
}

// MARK: - 行

/// 一条已知主机（设置页的列表行样式）：地址 / 指纹（等宽，可选中复制）、密钥类型、信任日期、删除钮。
private struct KnownHostRow: View {
    let host: KnownHost
    let onDelete: () -> Void

    var body: some View {
        SettingsListRow(icon: "checkmark.shield.fill", tint: UD.success,
                        title: host.displayAddress,
                        subtitle: host.fingerprint, subtitleStyle: .monospaced) {
            HStack(spacing: 10) {
                Text(host.keyTypeLabel)
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text2)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillFaint))
                    .fixedSize()
                Text(host.trustedDateText)
                    .font(UD.monoMetric)
                    .foregroundStyle(UD.text3)
                    .fixedSize()
                UDIconButton(systemImage: "trash", size: 26, style: .danger, action: onDelete)
                    .help("删除")
                    .accessibilityLabel("删除 \(host.displayAddress) 的指纹")
            }
        }
    }
}

// MARK: - 删除确认弹层

/// 删除已知主机指纹的确认弹层。
private struct KnownHostDeleteConfirm: View {
    let address: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        UDConfirmModal(title: KnownHostCopy.deleteTitle(address: address), width: 400,
                       onCancel: onCancel, onConfirm: onConfirm) {
            Text(KnownHostCopy.deleteMessage)
        }
    }
}

/// 自绘扁平标题栏（同 `KeysTitleBar`）：左侧让位红绿灯，居中图标 + 标题。
private struct KnownHostsTitleBar: View {
    var body: some View {
        ZStack {
            HStack(spacing: 9) {
                Image(systemName: "shield")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.accent)
                Text("已知主机指纹")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
            }
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear.frame(width: 68)   // 让位窗口红绿灯
                Spacer()
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

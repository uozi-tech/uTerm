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
                Rectangle().fill(UD.border).frame(height: 1)
                list
                Rectangle().fill(UD.border).frame(height: 1)
                footer
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        // 自绘扁平 chrome（同密钥 / 分组管理窗口）：透明系统标题栏 + 让位红绿灯的自绘标题栏。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "已知主机指纹"))
        .overlay { deleteConfirmOverlay }
    }

    // MARK: - 搜索 / 列表

    private var searchBar: some View {
        UDSearchField(text: $query, placeholder: "按地址或指纹搜索", showsHotkeyChip: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        let rows = filtered
        if rows.isEmpty {
            Text("没有匹配「\(query)」的主机")
                .font(.system(size: 12))
                .foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // 懒加载：连过几百台机器的库里 KnownHost 有上千行。
                LazyVStack(spacing: 0) {
                    ForEach(rows) { host in
                        KnownHostRow(host: host, onDelete: { pendingDelete = host })
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(hosts.count) 台已知主机")
            Spacer()
            Text("首次连接或主机密钥变化时，uTerm 会要求你确认指纹后才信任。")
        }
        .font(.system(size: 11))
        .foregroundStyle(UD.text4)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
                .foregroundStyle(UD.text4)
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

/// 一条已知主机：地址 / 指纹（等宽，可选中复制）/ 密钥类型 / 信任日期 / 删除钮。
private struct KnownHostRow: View {
    let host: KnownHost
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield")
                .font(.system(size: 13))
                .foregroundStyle(UD.text3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(host.displayAddress)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    Text(host.keyTypeLabel)
                        .font(UD.mono(10.5))
                        .foregroundStyle(UD.text3)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillSoft))
                }
                Text(host.fingerprint)
                    .font(UD.mono(11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(host.trustedDateText)
                .font(UD.monoMetric)
                .foregroundStyle(UD.text4)
            UDIconButton(systemImage: "trash", size: 24, action: onDelete)
                .help("删除")
                .accessibilityLabel("删除 \(host.displayAddress) 的指纹")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UD.rowHover : Color.clear))
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}

// MARK: - 删除确认弹层

/// 删除已知主机指纹的确认弹层（同 `KeyDeleteConfirm` 的居中卡片 + 半透明遮罩）。
private struct KnownHostDeleteConfirm: View {
    let address: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            UDModalBackdrop(onDismiss: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UD.danger.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(UD.danger.opacity(0.3), lineWidth: 1))
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(UD.danger))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(KnownHostCopy.deleteTitle(address: address))
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(UD.text)
                        Text(KnownHostCopy.deleteMessage)
                            .font(.system(size: 12)).foregroundStyle(UD.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: "删除", style: .danger, action: onConfirm)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 12).fill(UD.overlayHi))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UD.borderHi, lineWidth: 1))
            .shadow(color: UD.modalShadowColor, radius: 30, y: 18)
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

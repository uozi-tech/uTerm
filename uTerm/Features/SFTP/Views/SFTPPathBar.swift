import UDesignKit
import SwiftUI

enum SFTPPathBarLayout {
    nonisolated static let currentCrumbLeadingGap: CGFloat = 8

    nonisolated static func leadingGapForCrumb(index: Int, isLast: Bool) -> CGFloat {
        isLast && index > 0 ? currentCrumbLeadingGap : 0
    }
}

/// 路径栏（48px）：后退/前进 + 可点击面包屑 + 过滤框 + 上传/新建/刷新 + 在工作区打开 + 操作菜单。
/// 对齐设计稿 `pages/sftp.jsx` 的 `SftpPathBar`。
///
/// 浏览态下拆成两段分别坐在两栏顶上：`.leading`（导航、面包屑、过滤、上传 / 新建 / 刷新）
/// 在文件表那栏，`.trailing`（在工作区打开、操作）在检视器那栏，栏间竖线从卡顶通到卡底。
/// 原先整条横跨两栏，上传 / 新建两枚按钮正好骑在下方竖线两侧、不归属任何一栏（实机反馈）。
/// 连接中 / 失败等没有检视器的状态用 `.full`。
struct SFTPPathBar: View {
    enum Part { case full, leading, trailing }

    let path: String
    let canBack: Bool
    let canFwd: Bool
    let onBack: () -> Void
    let onFwd: () -> Void
    let onCrumb: (String) -> Void
    @Binding var query: String
    let onUpload: () -> Void
    let onNewFolder: () -> Void
    let onRefresh: () -> Void
    let showHidden: Bool
    let onToggleHidden: () -> Void
    let onOpenInTerminal: () -> Void
    /// 「在工作区打开」显眼按钮（accent 着色）——打开该服务器的工作区窗口。
    let onOpenWorkspace: () -> Void
    let sortKey: FileBrowserModel.SortKey
    let onSetSort: (FileBrowserModel.SortKey) -> Void
    var part: Part = .full

    private var crumbs: [(name: String, full: String)] {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var acc = ""
        var out: [(String, String)] = [("/", "/")]
        for c in comps { acc += "/" + c; out.append((c, acc)) }
        return out
    }

    var body: some View {
        HStack(spacing: 10) {
            if part != .trailing {
                HStack(spacing: 2) {
                    navArrow("chevron.left", enabled: canBack, label: "后退", action: onBack)
                    navArrow("chevron.right", enabled: canFwd, label: "前进", action: onFwd)
                }

                breadcrumbs
                    .frame(maxWidth: .infinity, alignment: .leading)

                filterField

                SFTPToolButton(systemName: "square.and.arrow.up", help: "上传文件", action: onUpload)
                SFTPToolButton(systemName: "folder.badge.plus", help: "新建文件夹", action: onNewFolder)
                SFTPToolButton(systemName: "arrow.clockwise", help: "刷新", action: onRefresh)
            } else {
                Spacer(minLength: 0)
            }

            if part != .leading {
                SFTPOpenWorkspaceButton(action: onOpenWorkspace)

                actionsMenu
            }
        }
        .padding(.horizontal, 12)
        // 分区方案 v3：路径栏并入内容卡顶部（48 高），无底线 —— 下方表头线就是分界。
        .frame(height: 48)
    }

    // MARK: 后退 / 前进

    private func navArrow(_ name: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? UD.text2 : UD.text4)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .hoverBackground(enabled ? UD.rowHover : .clear, cornerRadius: 7)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: 面包屑

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(UD.text4)
                    }
                    crumbButton(index: i, name: c.name, full: c.full)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func crumbButton(index i: Int, name: String, full: String) -> some View {
        let isLast = i == crumbs.count - 1
        return Button { onCrumb(full) } label: {
            HStack(spacing: 5) {
                if i == 0 {
                    // 文件系统根 `/` —— 只用磁盘图标，不写「root」文字，避免和真正的
                    // /root 目录撞名。
                    Image(systemName: "internaldrive.fill").font(.system(size: 11))
                        .foregroundStyle(isLast ? UD.accent : UD.accent.opacity(0.85))
                } else {
                    Text(name)
                        .font(.system(size: 13, weight: isLast ? .medium : .regular))
                        .foregroundStyle(isLast ? UD.text : UD.text2)
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .help(i == 0 ? "根目录 /" : full)
        .accessibilityLabel(i == 0 ? "根目录" : "进入目录 \(name)")
        .accessibilityValue(full)
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isLast ? UD.fillSoft : .clear))
        .hoverBackground(isLast ? .clear : UD.rowHover, cornerRadius: 7, isActive: isLast)
        .padding(.leading, SFTPPathBarLayout.leadingGapForCrumb(index: i, isLast: isLast))
    }

    // MARK: 过滤

    private var filterField: some View {
        UDSearchField(text: $query, width: 200, showsHotkeyChip: false)
    }

    // MARK: 操作菜单

    private var actionsMenu: some View {
        UDDropdown(anchor: .trailing) { open in
            HStack(spacing: 7) {
                Text("操作").font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        } content: {
            UDMenu(width: 200, head: "排序", items: actionsMenuItems)
        }
        .accessibilityLabel("操作菜单")
        .help("排序、显示隐藏文件、在终端中打开")
    }

    private var actionsMenuItems: [UDMenuItem] {
        var items: [UDMenuItem] = FileBrowserModel.SortKey.allCases.map { key in
            UDMenuItem(label: key.label, active: key == sortKey, action: { onSetSort(key) })
        }
        items.append(.divider())
        items.append(UDMenuItem(label: "显示隐藏文件", active: showHidden, action: onToggleHidden))
        items.append(.divider())
        items.append(UDMenuItem(label: "在终端中打开", systemImage: "terminal", action: onOpenInTerminal))
        return items
    }
}

/// 路径栏右侧淡底方形图标按钮（WS 配色，hover 提亮 + 提底）。
struct SFTPToolButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(hover ? UD.text : UD.text2)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(hover ? UD.panelHover : UD.fillFaint))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 路径栏「在工作区打开」显眼按钮：accent 着色淡底 + 终端图标 + 文案。对齐设计稿
/// `pages/sftp.jsx` 里操作菜单左侧那枚强调按钮（着色态，非实心）。
struct SFTPOpenWorkspaceButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "terminal").font(.system(size: 12))
                    .foregroundStyle(UD.accentInk)
                Text("在工作区打开").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.accentInk)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hover ? UD.accent.opacity(0.22) : UD.accentSoft))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
        .help("在工作区中打开此连接（终端 + Agent）")
        .accessibilityLabel("在工作区打开")
    }
}

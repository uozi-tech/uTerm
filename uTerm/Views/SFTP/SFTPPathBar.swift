import SwiftUI

/// 路径栏（50px）：后退/前进 + 可点击面包屑 + 过滤框 + 上传/新建/刷新 + 操作菜单。
/// WS 暗色调色板，对齐设计稿 `pages/sftp.jsx` 的 `SftpPathBar`。
struct SFTPPathBar: View {
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
    let sortKey: FileBrowserModel.SortKey
    let onSetSort: (FileBrowserModel.SortKey) -> Void

    @FocusState private var filterFocused: Bool

    private var crumbs: [(name: String, full: String)] {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var acc = ""
        var out: [(String, String)] = [("/", "/")]
        for c in comps { acc += "/" + c; out.append((c, acc)) }
        return out
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                navArrow("chevron.left", enabled: canBack, action: onBack)
                navArrow("chevron.right", enabled: canFwd, action: onFwd)
            }

            breadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            filterField

            SFTPToolButton(systemName: "square.and.arrow.up", help: "上传文件", action: onUpload)
            SFTPToolButton(systemName: "folder.badge.plus", help: "新建文件夹", action: onNewFolder)
            SFTPToolButton(systemName: "arrow.clockwise", help: "刷新", action: onRefresh)

            actionsMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    // MARK: 后退 / 前进

    private func navArrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
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
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isLast ? UD.fillSoft : .clear))
        .hoverBackground(isLast ? .clear : UD.rowHover, cornerRadius: 7, isActive: isLast)
    }

    // MARK: 过滤

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(UD.text3)
            TextField("", text: $query, prompt: Text("过滤").foregroundStyle(UD.text4))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .frame(width: 150)
                .focused($filterFocused)
        }
        .padding(.horizontal, 11).frame(width: 200, height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(filterFocused ? UD.accent : UD.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: filterFocused)
    }

    // MARK: 操作菜单

    private var actionsMenu: some View {
        Menu {
            Section("排序") {
                ForEach(FileBrowserModel.SortKey.allCases) { key in
                    Button { onSetSort(key) } label: {
                        HStack {
                            Text(key.label)
                            if key == sortKey { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Divider()
            Button { onToggleHidden() } label: {
                HStack {
                    Text("显示隐藏文件")
                    if showHidden { Image(systemName: "checkmark") }
                }
            }
            Divider()
            Button("在终端中打开", action: onOpenInTerminal)
        } label: {
            HStack(spacing: 7) {
                Text("操作").font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 路径栏右侧带描边的方形图标按钮（WS 配色，hover 提亮 + 提底）。
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
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

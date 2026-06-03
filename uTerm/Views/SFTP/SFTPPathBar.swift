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
        .overlay(alignment: .bottom) { Rectangle().fill(WS.border).frame(height: 1) }
    }

    // MARK: 后退 / 前进

    private func navArrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? WS.text2 : WS.text4)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .hoverBackground(enabled ? WS.rowHover : .clear, cornerRadius: 7)
    }

    // MARK: 面包屑

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(WS.text4)
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
                    Image(systemName: "house.fill").font(.system(size: 10))
                        .foregroundStyle(WS.accent.opacity(0.9))
                }
                Text(i == 0 ? "root" : name)
                    .font(.system(size: 13, weight: isLast ? .medium : .regular))
                    .foregroundStyle(isLast ? WS.text : WS.text2)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isLast ? Color.white.opacity(0.05) : .clear))
        .hoverBackground(isLast ? .clear : WS.rowHover, cornerRadius: 7, isActive: isLast)
    }

    // MARK: 过滤

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(WS.text3)
            TextField("", text: $query, prompt: Text("过滤").foregroundStyle(WS.text4))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(WS.text)
                .frame(width: 150)
                .focused($filterFocused)
        }
        .padding(.horizontal, 11).frame(width: 200, height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(filterFocused ? WS.accent : WS.border, lineWidth: 1))
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
                Text("操作").font(.system(size: 13, weight: .medium)).foregroundStyle(WS.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WS.text3)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WS.border, lineWidth: 1))
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
                .foregroundStyle(hover ? WS.text : WS.text2)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(hover ? WS.panelHover : Color.white.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

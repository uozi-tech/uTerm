import SwiftUI

/// 右侧检视器（300px）：空态 / 选中态（大图标 + 属性表 + 远程路径 + 下载/重命名/删除）。
/// WS 暗色调色板，对齐设计稿 `pages/sftp.jsx` 的 `Inspector`。
struct SFTPInspector: View {
    let item: RemoteEntry?
    let currentPath: String
    let onDownload: (RemoteEntry) -> Void
    let onOpenFolder: (RemoteEntry) -> Void
    let onOpenWorkspace: () -> Void
    let onPermissions: (RemoteEntry) -> Void
    let onRename: (RemoteEntry) -> Void
    let onDelete: (RemoteEntry) -> Void

    var body: some View {
        if let item {
            detail(item)
        } else {
            empty
        }
    }

    // MARK: 空态

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(UD.text4)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(UD.fillFaint))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UD.border, lineWidth: 1))
            VStack(spacing: 6) {
                Text("未选择文件").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(UD.text2)
                Text("在左侧选择一个文件或文件夹\n即可查看详情并进行操作。")
                    .font(.system(size: 12.5)).multilineTextAlignment(.center)
                    .foregroundStyle(UD.text4).lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 30)
    }

    // MARK: 选中态

    private func detail(_ item: RemoteEntry) -> some View {
        let kind = BrowserFileKind.from(name: item.name, isDirectory: item.isDirectory, isSymlink: item.isSymlink)
        let fullPath = currentPath == "/" ? "/\(item.name)" : "\(currentPath)/\(item.name)"
        let sizeText = item.isDirectory ? "文件夹"
            : (item.size.map { SFTPFormat.bytes(Int64($0)) } ?? "--")
        let rows: [(String, String, Bool)] = [
            ("种类", kind.label, false),
            ("大小", sizeText, false),
            ("修改时间", item.modifiedAt.map { SFTPFormat.date($0) } ?? "--", false),
            ("权限", posixPermissionString(item.permissions), true),
            ("所有者", "\(item.uid.map(String.init) ?? "?") · \(item.gid.map(String.init) ?? "?")", false),
        ]
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    // 大图标 + 名称
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(item.isDirectory ? UD.accent.opacity(0.10)
                                                       : UD.fillFaint)
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
                                    item.isDirectory ? UD.accent.opacity(0.28) : UD.border, lineWidth: 1))
                                .frame(width: 84, height: 84)
                            SFTPFileIcon(kind: kind).scaleEffect(2.1)
                        }
                        VStack(spacing: 4) {
                            Text(item.name).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(UD.text)
                                .multilineTextAlignment(.center)
                            Text(sizeText).font(UD.mono(12)).foregroundStyle(UD.text3)
                        }
                    }
                    .padding(.top, 24)

                    // 属性
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(r.0).font(.system(size: 12)).foregroundStyle(UD.text4)
                                    .frame(width: 64, alignment: .leading)
                                Spacer(minLength: 0)
                                Text(r.1)
                                    .font(r.2 ? UD.mono(12) : .system(size: 12.5))
                                    .foregroundStyle(UD.text2)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .top) {
                                if i > 0 { Rectangle().fill(UD.border).frame(height: 1) }
                            }
                        }
                    }

                    // 路径
                    VStack(alignment: .leading, spacing: 6) {
                        Text("路径").font(.system(size: 10.5, weight: .medium))
                            .tracking(0.5).foregroundStyle(UD.text4)
                        Text(fullPath).font(UD.mono(11.5))
                            .foregroundStyle(UD.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 7).fill(UD.terminal))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.border, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 18)
            }

            // 操作区
            Rectangle().fill(UD.border).frame(height: 1)
            VStack(spacing: 8) {
                primaryButton(item)
                SFTPSecondaryButton(label: "在工作区打开", systemImage: "terminal") { onOpenWorkspace() }
                SFTPSecondaryButton(label: "权限设置…", systemImage: "lock") { onPermissions(item) }
                HStack(spacing: 8) {
                    SFTPSecondaryButton(label: "重命名") { onRename(item) }
                    SFTPSecondaryButton(label: "删除", danger: true) { onDelete(item) }
                }
            }
            .padding(14)
        }
    }

    private func primaryButton(_ item: RemoteEntry) -> some View {
        Button {
            if item.isDirectory { onOpenFolder(item) } else { onDownload(item) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.isDirectory ? "arrow.right" : "arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text(item.isDirectory ? "进入" : "下载")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(UD.accent))
            .shadow(color: UD.accent.opacity(0.45), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
    }
}

/// 检视器底部次级按钮：默认 WS 描边；danger 用红色描边 + 红字。
struct SFTPSecondaryButton: View {
    let label: String
    var systemImage: String? = nil
    var danger: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12))
                }
                Text(label).font(.system(size: 12.5))
            }
                .foregroundStyle(danger ? UD.danger : UD.text2)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hover ? UD.rowHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                    danger ? UD.danger.opacity(0.32) : UD.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

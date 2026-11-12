import AppKit
import SwiftUI
import UDesignKit

/// 「我的 Mac」详情里的共享文件夹：本机把哪些文件夹开放给这台被控的 Mac。
///
/// 开放之后，那台 Mac 终端里的程序（Agent、`utermctl mac …`）可以经远控链路读写这些文件夹里的东西；
/// 别的地方读不到，也不能在本机跑命令。默认只读，要改得单独打开。
struct RemoteSharedFoldersSection: View {
    let mac: RemoteMacDirectory.Mac
    let store: RemoteFileSharingStore

    var body: some View {
        let roots = store.roots(for: mac.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("共享文件夹")
                    .font(.system(size: 10.5))
                    .tracking(0.5)
                    .foregroundStyle(UD.text3)
                Spacer(minLength: 0)
                UDIconButton(systemImage: "plus", size: 22, action: add)
                    .help("共享一个文件夹给这台 Mac")
                    .accessibilityLabel("添加共享文件夹")
            }
            if roots.isEmpty {
                Text("没有共享。添加之后，那台 Mac 终端里的程序可以读取这些文件夹里的文件。")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(roots, id: \.path) { root in
                        RemoteSharedFolderRow(root: root,
                                              onWritable: { store.setWritable($0, path: root.path, for: mac.id) },
                                              onRemove: { store.remove(root.path, for: mac.id) })
                    }
                }
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "共享")
        panel.message = String(localized: "选择要共享给「\(mac.name)」的文件夹")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.add(url.path, writable: false, for: mac.id)
        }
    }
}

private struct RemoteSharedFolderRow: View {
    let root: RemoteFileRoot
    let onWritable: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
            Text(RemoteSharedFoldersSection.display(root.path))
                .font(.system(size: 12))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.head)
                .help(root.path)
            Spacer(minLength: 4)
            Menu {
                Button("只读") { onWritable(false) }
                Button("读写") { onWritable(true) }
            } label: {
                Text(root.writable ? "读写" : "只读")
                    .font(.system(size: 11.5))
                    .foregroundStyle(root.writable ? UD.warning : UD.text2)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(root.writable ? "那台 Mac 可以改这个文件夹里的东西" : "那台 Mac 只能读")
            UDIconButton(systemImage: "xmark", size: 20, action: onRemove)
                .help("不再共享")
                .accessibilityLabel("不再共享 \(root.path)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(UD.inputBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension RemoteSharedFoldersSection {
    /// 主目录开头的路径写成 `~/…`。
    nonisolated static func display(_ path: String, home: String = RemoteSharedFoldersSection.userHome) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// 真实的主目录（沙盒里 `NSHomeDirectory()` 是容器目录）。
    nonisolated static var userHome: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }
}

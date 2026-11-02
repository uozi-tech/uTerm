import UDesignKit
import SwiftUI

// MARK: - 下钻页自绘内联头部
// 根操作单与下钻页（权限 / 简介）整栈都隐藏系统导航栏，下钻页改用这套自绘头部。
// 这样下钻推进时系统栏不再发生「隐藏→显示」的过渡：顶部安全区 inset 全程恒定，
// ScrollView 不会在推进动画里追赶 inset 变化 → 不再「padding 先很小再抖动」掉帧。
struct MSheetNavHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()                 // 栈内有下钻条目 → 仅回退一级，不关整张操作单
            } label: {
                MIcon(name: "back", size: 16, color: accent, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .background(M.button)
                    .clipShape(Circle())
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel("返回")
            Text(title).font(M.sans(16, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 9).padding(.trailing, 14).padding(.top, M.topBreath).padding(.bottom, 5)
        // pinned 头部需不透明底，避免内容滚动时透出；与下方内容同为 canvas，只靠底边 hairline 分区。
        .background(M.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }
}

// MARK: - POSIX 权限位换算（设计稿 m-overlays 的 permParse/permStr/permOctal）

enum POSIXPerm {
    /// mode → 9 个布尔位，顺序 rwx(owner) rwx(group) rwx(other)。
    static func bits(from mode: UInt32) -> [Bool] {
        (0..<9).map { (mode & (1 << UInt32(8 - $0))) != 0 }
    }
    static func mode(from bits: [Bool]) -> UInt32 {
        var m: UInt32 = 0
        for (i, b) in bits.enumerated() where b { m |= (1 << UInt32(8 - i)) }
        return m
    }
    static func octal(_ bits: [Bool]) -> String {
        func g(_ a: Bool, _ b: Bool, _ c: Bool) -> Int { (a ? 4 : 0) + (b ? 2 : 0) + (c ? 1 : 0) }
        return "\(g(bits[0], bits[1], bits[2]))\(g(bits[3], bits[4], bits[5]))\(g(bits[6], bits[7], bits[8]))"
    }
    static func symbolic(_ bits: [Bool], isDir: Bool) -> String {
        let ch = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        let body = bits.enumerated().map { $0.element ? ch[$0.offset] : "-" }.joined()
        return (isDir ? "d" : "-") + body
    }
    static func initialBits(_ entry: RemoteEntry) -> [Bool] {
        let mode = entry.permissions.map { $0 & 0o777 } ?? (entry.isDirectory ? 0o755 : 0o644)
        return bits(from: mode)
    }
}

// MARK: - chmod 编辑器（设计稿 PermissionSheet），作为操作单内的下钻页

struct PermissionGrid: View {
    let entry: RemoteEntry
    /// 父级负责实际 chmod 并关闭整张操作单。
    var onApply: (UInt32) -> Void
    @Environment(\.mAccent) private var accent
    @State private var bits: [Bool]

    init(entry: RemoteEntry, onApply: @escaping (UInt32) -> Void) {
        self.entry = entry
        self.onApply = onApply
        _bits = State(initialValue: POSIXPerm.initialBits(entry))
    }

    private let classes: [(String, Int)] = [("所有者", 0), ("群组", 3), ("其他", 6)]
    private let cols: [(String, Int)] = [("读", 0), ("写", 1), ("执行", 2)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text(POSIXPerm.octal(bits)).font(M.mono(30, weight: .bold))
                        .foregroundStyle(accent).tracking(1)
                    Rectangle().fill(M.divider).frame(width: 1, height: 26)
                    Text(POSIXPerm.symbolic(bits, isDir: entry.isDirectory))
                        .font(M.mono(16)).foregroundStyle(M.text2).tracking(1)
                }
                .padding(.vertical, 18)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("类别").font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16)
                        ForEach(cols, id: \.0) { c in
                            Text(c.0).font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.text3).frame(width: 64)
                        }
                    }
                    // 表头与行同在卡片面上，只靠底边 hairline 分区（不再叠一层更深的底色）。
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }

                    ForEach(Array(classes.enumerated()), id: \.element.0) { ci, cls in
                        HStack(spacing: 0) {
                            Text(cls.0).font(M.sans(14.5)).foregroundStyle(M.text)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16)
                            ForEach(cols, id: \.0) { col in
                                let idx = cls.1 + col.1
                                MCheck(checked: bits[idx]) { _ in bits[idx].toggle() }.frame(width: 64)
                            }
                        }
                        .frame(height: 52)
                        .overlay(alignment: .top) { if ci > 0 { Rectangle().fill(M.divider).frame(height: 1) } }
                    }
                }
                .background(M.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)

                MBtn(title: "应用", full: true, height: 48) { onApply(POSIXPerm.mode(from: bits)) }
                    .padding(.horizontal, 16).padding(.top, 20)
            }
            .padding(.vertical, 8)
        }
        .background(M.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { MSheetNavHeader(title: "权限") }
        .toolbar(.hidden, for: .navigationBar)   // 整栈隐藏系统栏：下钻全程 top inset 恒定
    }
}

// MARK: - 文件简介

struct FileInfoView: View {
    let entry: RemoteEntry
    let fullPath: String
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MInsetGroup(header: "信息") {
                    MInsetRow(label: "名称", value: entry.name)
                    MInsetRow(label: "类型",
                              value: entry.isDirectory ? "文件夹" : (entry.isSymlink ? "符号链接" : "文件"))
                    if !entry.isDirectory, let s = entry.size {
                        MInsetRow(label: "大小",
                                  value: UFormat.bytes(Int64(clamping: s)))
                    }
                    if let p = entry.permissions {
                        MInsetRow(label: "权限", value: String(format: "%o", p & 0o777), valueMono: true)
                    }
                    MInsetRow(label: "路径", value: fullPath, valueMono: true, last: true)
                }
            }
            .padding(.top, 12)
        }
        .background(M.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { MSheetNavHeader(title: "简介") }
        .toolbar(.hidden, for: .navigationBar)   // 整栈隐藏系统栏：下钻全程 top inset 恒定
    }
}

/// 操作单内容真实高度测量 key（抽屉按内容贴合）。
private struct FileSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 420
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 系统分享面板桥接

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 文件操作单（设计稿 FileActionSheet · 长按上下文菜单）

struct FileActionSheet: View {
    let entry: RemoteEntry
    let fullPath: String
    var onEnter: () -> Void
    var onCopyPath: () -> Void
    var onRename: () -> Void
    var onDownload: () -> Void
    /// 应用 chmod（由内部下钻的 PermissionGrid 回调，父级落地后关单）。
    var onChmod: (UInt32) -> Void
    var onDelete: () -> Void
    @Environment(\.mAccent) private var accent

    private var isFolder: Bool { entry.isDirectory }
    private var subtitle: String {
        let kind = isFolder ? "文件夹" : (entry.size.map { UFormat.bytes(Int64(clamping: $0)) } ?? "文件")
        let perm = entry.permissions.map { String(format: "%o", $0 & 0o777) } ?? "—"
        return "\(kind) · \(perm)"
    }

    var body: some View {
        // 权限 / 简介在本单内**下钻 + 返回**，不再各开新抽屉（复用导航返回）。
        // 固定 detent（非按内容贴合）→ 推进时不改抽屉高度、无抖动。
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 8)
                    if isFolder { actionRow("folder-tag", "进入文件夹", action: onEnter) }
                    actionRow("download", "下载", action: onDownload)
                    actionRow("copy", "复制路径", action: onCopyPath)
                    actionRow("edit", "重命名", action: onRename)
                    NavigationLink { PermissionGrid(entry: entry, onApply: onChmod) } label: {
                        actionLabel("lock", "权限…", chevron: true)
                    }.buttonStyle(MRowStyle())
                    NavigationLink { FileInfoView(entry: entry, fullPath: fullPath) } label: {
                        actionLabel("info", "简介", chevron: true)
                    }.buttonStyle(MRowStyle())
                    Rectangle().fill(M.divider).frame(height: 1).padding(.vertical, 8)
                    actionRow("trash", "删除", danger: true, action: onDelete)
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(M.canvas)
            .toolbar(.hidden, for: .navigationBar)   // 根（动作单）自绘头部；整栈同一隐藏 API → 下钻无栏过渡
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MIcon(name: isFolder ? "folder" : "file", size: 18, color: accent)
                .frame(width: 38, height: 38).background(accent.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(M.sans(16, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                Text(subtitle).font(M.mono(12.5)).foregroundStyle(M.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private func actionRow(_ icon: String, _ label: String, danger: Bool = false, chevron: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, label, danger: danger, chevron: chevron) }
            .buttonStyle(MRowStyle())
    }

    private func actionLabel(_ icon: String, _ label: String,
                             danger: Bool = false, chevron: Bool = false) -> some View {
        HStack(spacing: 13) {
            MIcon(name: icon, size: 19, color: danger ? M.danger : M.text2)
            Text(label).font(M.sans(15.5)).foregroundStyle(danger ? M.danger : M.text)
            Spacer()
            if chevron { MIcon(name: "chev", size: 13, color: M.text4, weight: .semibold) }
        }
        .padding(.horizontal, 8).padding(.vertical, 13)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

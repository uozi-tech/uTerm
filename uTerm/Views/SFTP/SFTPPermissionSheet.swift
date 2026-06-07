import SwiftUI

/// 权限设置（chmod）对话框——**刻意精简**（用户反馈：不要过度设计）。对齐设计稿
/// `pages/file-ops.jsx` 的 `PermissionDialog`：
/// - 顶部：文件名 + 「权限」标题。
/// - 实时预览：大号八进制（accent）+ 符号串（mono）。
/// - 3×3 网格：行 = 所有者 / 群组 / 其他；列 = 读 r / 写 w / 执行 x。
/// - 目录额外一行「应用到此文件夹包含的所有项目」（递归）。
/// - 底部：取消 / 应用。
///
/// **不做** setuid/setgid/sticky、owner/group 改派、命令行提示。状态是 9 位 `bits`
/// （u/g/o × r/w/x），应用时拼成 `UInt32`（`& 0o777`）交回调用方下发 chmod。
struct SFTPPermissionSheet: View {
    let entry: RemoteEntry
    /// 应用回调：(mode 权限位 & 0o777, recursive)。
    let onApply: (UInt32, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bits: [Bool]
    @State private var recursive = false

    private static let masks: [UInt32] = [
        0o400, 0o200, 0o100,
        0o040, 0o020, 0o010,
        0o004, 0o002, 0o001,
    ]
    private static let symbols = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
    private static let classes = ["所有者", "群组", "其他"]
    private static let cols = ["读", "写", "执行"]

    init(entry: RemoteEntry, onApply: @escaping (UInt32, Bool) -> Void) {
        self.entry = entry
        self.onApply = onApply
        // nil 权限时给合理默认：目录 755 / 符号链接 777 / 普通文件 644。
        let initial = entry.permissions.map { $0 & 0o777 }
            ?? (entry.isDirectory ? 0o755 : (entry.isSymlink ? 0o777 : 0o644))
        _bits = State(initialValue: Self.masks.map { (initial & $0) != 0 })
    }

    private var typeChar: String {
        entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
    }
    private var mode: UInt32 {
        var m: UInt32 = 0
        for (i, on) in bits.enumerated() where on { m |= Self.masks[i] }
        return m
    }
    private var octal: String {
        func g(_ base: Int) -> String {
            String((bits[base] ? 4 : 0) + (bits[base + 1] ? 2 : 0) + (bits[base + 2] ? 1 : 0))
        }
        return g(0) + g(3) + g(6)
    }
    private var symbolic: String {
        typeChar + bits.enumerated().map { $0.element ? Self.symbols[$0.offset] : "-" }.joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            VStack(spacing: 16) {
                preview
                grid
                if entry.isDirectory {
                    Button { recursive.toggle() } label: {
                        HStack(spacing: 10) {
                            PermCheckbox(on: recursive) { recursive.toggle() }
                            Text("应用到此文件夹包含的所有项目")
                                .font(.system(size: 12.5)).foregroundStyle(UD.text2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            Rectangle().fill(UD.border).frame(height: 1)
            footer
        }
        .frame(width: 360)
        .background(UD.overlayHi)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("权限").font(.system(size: 14, weight: .semibold)).foregroundStyle(UD.text)
            Text(entry.name).font(UD.mono(12)).foregroundStyle(UD.text3)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
    }

    // MARK: 实时预览

    private var preview: some View {
        HStack(spacing: 12) {
            Text(octal)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(UD.accent).tracking(1)
            Rectangle().fill(UD.border).frame(width: 1, height: 22)
            Text(symbolic)
                .font(UD.mono(14)).foregroundStyle(UD.text2).tracking(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 3×3 网格

    private var grid: some View {
        VStack(spacing: 0) {
            // 列头
            gridRow(leading: Text("类别").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UD.text3)) { col in
                Text(Self.cols[col]).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.text3)
            }
            .background(UD.fillFaint)
            Rectangle().fill(UD.border).frame(height: 1)
            // 三行
            ForEach(Array(Self.classes.enumerated()), id: \.offset) { ri, name in
                if ri > 0 { Rectangle().fill(UD.border).frame(height: 1) }
                gridRow(leading: Text(name).font(.system(size: 13)).foregroundStyle(UD.text)) { col in
                    PermCheckbox(on: bits[ri * 3 + col]) { bits[ri * 3 + col].toggle() }
                }
                .frame(height: 42)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// 一行网格：leading 文案占满左侧，右侧三列等宽（56）放 cell。三列直接展开
    /// 调用（不走 ForEach）——`cell` 是非逃逸参数，放进 ForEach 的逃逸 ViewBuilder
    /// 闭包会触发「escaping closure captures non-escaping parameter」。
    private func gridRow<L: View, C: View>(
        leading: L, @ViewBuilder cell: (Int) -> C
    ) -> some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
            cell(0).frame(width: 56)
            cell(1).frame(width: 56)
            cell(2).frame(width: 56)
        }
        .frame(minHeight: 34)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            UDButton(title: "取消", style: .secondary) { dismiss() }
            UDButton(title: "应用", style: .primary) {
                onApply(mode, recursive)
                dismiss()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// 权限网格用的小方形勾选框（自绘，匹配 WS 暗色语言：选中 accent 填充 + 白勾，
/// 未选 `UD.fillSoft` 底 + `UD.border` 描边）。不用系统 `.checkbox` 以避免系统蓝。
private struct PermCheckbox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? UD.accent : UD.fillSoft)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(on ? UD.accent : UD.border, lineWidth: 1))
                .frame(width: 18, height: 18)
                .overlay {
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

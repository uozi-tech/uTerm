import SwiftUI
import AppKit

/// 单把密钥的详情面板（设计稿 `keys.jsx` 的 `KeyDetail`）：头部（头像 + 可重命名
/// 名称 + 算法/创建时间）、指纹、公钥、元信息三宫格、使用此密钥的主机、危险区删除。
struct KeyDetailView: View {
    let key: SSHKey
    let usedByNames: [String]
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                fingerprintBlock
                publicKeyBlock
                metaGrid
                usageBlock
                dangerZone
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KeyAvatarLarge(type: key.type)
            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    UDTextField(placeholder: "名称", text: $draftName)
                        .frame(maxWidth: 260)
                        .onSubmit(commitRename)
                } else {
                    Text(key.name)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(UD.text)
                }
                Text(metaLine).font(UD.mono(12)).foregroundStyle(UD.text3)
            }
            Spacer(minLength: 0)
            UDButton(title: renaming ? "完成" : "重命名", style: .secondary) {
                if renaming {
                    commitRename()
                } else {
                    startRename()
                }
            }
        }
    }

    private var metaLine: String {
        let algo = key.type == .ed25519 ? "ed25519 · 256 bit" : "rsa · \(key.bits) bit"
        return "\(algo) · 创建于 \(Self.dateFmt.string(from: key.createdAt))"
    }

    private func startRename() { draftName = key.name; renaming = true }
    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onRename(trimmed) }
        renaming = false
    }

    // MARK: - 指纹

    private var fingerprintBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("指纹")
            HStack(spacing: 10) {
                Text(key.fingerprint.isEmpty ? "—" : key.fingerprint)
                    .font(UD.mono(11.5)).foregroundStyle(UD.text2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                CopyButton(text: key.fingerprint)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.border, lineWidth: 1))
        }
    }

    // MARK: - 公钥

    private var publicKeyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("公钥")
                Spacer()
                CopyButton(text: key.publicKey, label: "复制公钥", bordered: true)
            }
            Text(key.publicKey.isEmpty ? "—" : key.publicKey)
                .font(UD.mono(11.5)).foregroundStyle(UD.text2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(UD.terminal))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.border, lineWidth: 1))
        }
    }

    // MARK: - 三宫格

    private var metaGrid: some View {
        HStack(spacing: 1) {
            metaCell("注释", key.comment.isEmpty ? "—" : key.comment, mono: true)
            metaCell("口令", key.hasPassphrase ? "已设置" : "未设置")
            metaCell("上次使用", key.lastUsedAt.map { Self.relFmt.localizedString(for: $0, relativeTo: Date()) } ?? "从未")
        }
        .background(UD.border)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UD.border, lineWidth: 1))
    }

    private func metaCell(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10.5)).tracking(0.5).foregroundStyle(UD.text4)
            Text(value).font(mono ? UD.mono(13) : .system(size: 13)).foregroundStyle(UD.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(UD.bg)
    }

    // MARK: - 使用此密钥的主机

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("使用此密钥的主机 · \(usedByNames.count)")
            if usedByNames.isEmpty {
                Text("暂未被任何主机使用")
                    .font(.system(size: 12)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(UD.border))
            } else {
                WrapChips(names: usedByNames)
            }
        }
    }

    // MARK: - 危险区

    private var dangerZone: some View {
        let danger = Color(hex: 0xF87171)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("删除此密钥").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0xFCA5A5))
                Text("密钥将从钥匙串移除，使用此密钥的 \(usedByNames.count) 台主机将无法连接，需重新选择。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            UDButton(title: "删除", style: .danger, action: onDelete)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 8).fill(danger.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(danger.opacity(0.22), lineWidth: 1))
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5, weight: .medium)).tracking(0.6).foregroundStyle(UD.text4)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let relFmt = RelativeDateTimeFormatter()
}

// MARK: - 复制按钮

private struct CopyButton: View {
    let text: String
    var label: String = "复制"
    var bordered: Bool = false
    @State private var copied = false

    var body: some View {
        UDButton(title: copied ? "已复制" : label, style: bordered ? .secondary : .ghost) {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

private struct WrapChips: View {
    let names: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 5) {
                    Circle().fill(UD.accent).frame(width: 6, height: 6)
                    Text(name).font(UD.mono(11.5)).foregroundStyle(UD.text2)
                }
                .padding(.leading, 8).padding(.trailing, 9).padding(.vertical, 4)
                .background(Capsule().fill(UD.fillFaint))
                .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
            }
        }
    }
}

private struct KeyAvatarLarge: View {
    let type: SSHKeyKind
    var body: some View {
        let tint: Color = type == .ed25519 ? UD.accent : Color(hex: 0xFBBF24)
        RoundedRectangle(cornerRadius: 8)
            .fill(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .frame(width: 32, height: 32)
            .overlay(Image(systemName: "key.fill").font(.system(size: 15)).foregroundStyle(tint))
    }
}

/// 极简流式布局：chips 自动换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

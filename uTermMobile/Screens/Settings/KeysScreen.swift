import SwiftUI
import SwiftData

/// SSH 密钥库（真实 `SSHKey`）。生成（纯 Swift）/ 展示 / 复制公钥 / 删除；详情含使用主机与危险区。
struct KeysScreen: View {
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\SSHKey.createdAt, order: .reverse)]) private var keys: [SSHKey]
    /// 「用了这把钥匙的主机数」的数据源。
    ///
    /// 改前是行体里 `context.fetch(FetchDescriptor<ServerProfile>())` ——
    /// **每渲染一行就把整张 `ServerProfile` 表取出来物化一遍**再 filter，
    /// 十把钥匙就是十趟全表 fetch。`KeyDetailSheet` 本来就是用 `@Query` 拿的，
    /// 列表页照它写即可。
    @Query private var hosts: [ServerProfile]
    @State private var detail: SSHKey?
    @State private var generating = false

    var body: some View {
        // 一趟建「keyID → 台数」，行体只查表。
        let usage = keyUsage

        return Group {
            if keys.isEmpty {
                MEmptyState(icon: "key", title: "密钥库为空",
                            message: "在此生成 SSH 密钥（私钥存钥匙串），或从 macOS 端经 iCloud 同步。",
                            actionTitle: "生成密钥", action: { generating = true })
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        MBtn(title: "生成密钥", icon: "plus", kind: .tinted, full: true, height: 44) { generating = true }
                            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                        MInsetGroup {
                            ForEach(Array(keys.enumerated()), id: \.element.id) { idx, key in
                                MInsetRow(icon: "key", iconColor: M.warning, label: key.name,
                                          sub: "\(key.typeLabel) · \(usage[key.id] ?? 0) 主机", chevron: true,
                                          last: idx == keys.count - 1,
                                          onTap: { detail = key })
                            }
                        }
                        Text("\(keys.count) 把密钥 · 私钥保存在钥匙串，永不离开本机")
                            .font(M.sans(12)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 2)
                    }
                    .padding(.top, 12)
                    .mReadableColumn()
                }
            }
        }
        .background(M.canvas)
        .navigationTitle("SSH 密钥")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { generating = true } label: { MIcon(name: "plus", size: 18, color: accent) }
            }
        }
        .sheet(isPresented: $generating) { KeyGenSheet() }
        .sheet(item: $detail) { key in
            KeyDetailSheet(key: key).presentationDragIndicator(.visible)
        }
    }

    /// keyID → 使用它的主机数，一趟过。
    private var keyUsage: [UUID: Int] {
        var out: [UUID: Int] = [:]
        out.reserveCapacity(keys.count)
        for h in hosts {
            guard let id = h.keyID else { continue }
            out[id, default: 0] += 1
        }
        return out
    }
}

struct KeyDetailSheet: View {
    let key: SSHKey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var hosts: [ServerProfile]
    @State private var pendingDelete = false

    private var usedBy: [ServerProfile] { hosts.filter { $0.keyID == key.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MInsetGroup(header: "信息") {
                        MInsetRow(label: "名称", value: key.name)
                        MInsetRow(label: "算法", value: key.typeLabel, valueMono: true)
                        MInsetRow(label: "注释", value: key.comment.isEmpty ? "—" : key.comment)
                        MInsetRow(label: "口令保护", value: key.hasPassphrase ? "是" : "否", last: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: "指纹").padding(.horizontal, 20)
                        MCopyField(value: key.fingerprint).padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: "公钥").padding(.horizontal, 20)
                        MCopyField(value: key.publicKey).padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        MSectionCap(text: "使用此密钥的主机 · \(usedBy.count)").padding(.horizontal, 20)
                        if usedBy.isEmpty {
                            Text("暂未被任何主机使用").font(M.sans(12.5)).foregroundStyle(M.text4)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(M.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .padding(.horizontal, 16)
                        } else {
                            FlowChipsView(items: usedBy.map(\.name)).padding(.horizontal, 16)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("删除此密钥").font(M.sans(14, weight: .semibold)).foregroundStyle(Color(hexString: "#fca5a5"))
                        Text("密钥将从钥匙串移除，使用此密钥的 \(usedBy.count) 台主机将无法连接。")
                            .font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
                        MBtn(title: "删除密钥", icon: "trash", kind: .dangerTint, height: 42) { pendingDelete = true }
                            .fixedSize().padding(.top, 4)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(M.danger.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(M.danger.opacity(0.22), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
                .mReadableColumn()
            }
            .background(M.canvas)
            .navigationTitle(key.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("删除密钥「\(key.name)」？", isPresented: $pendingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
                Button("取消", role: .cancel) {}
            } message: { Text("此操作不可恢复。") }
        }
    }

    private func delete() {
        KeyStore().delete(keyID: key.id)
        context.delete(key)
        try? context.save()
        dismiss()
    }
}

/// 简单的横向流式标签（使用主机 chip）。
struct FlowChipsView: View {
    let items: [String]
    @Environment(\.mAccent) private var accent
    var body: some View {
        FlexWrap(spacing: 7, lineSpacing: 7) {
            ForEach(items, id: \.self) { name in
                HStack(spacing: 6) {
                    MDot(color: accent, size: 6)
                    Text(name).font(M.mono(12.5)).foregroundStyle(M.text2)
                }
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(M.fillFaint)
                .clipShape(Capsule())
            }
        }
    }
}

/// 极简自适应换行容器（基于 Layout 协议）。
struct FlexWrap: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

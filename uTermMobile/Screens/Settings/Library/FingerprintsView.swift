import SwiftUI
import SwiftData

/// 已知主机指纹（设计稿 `FingerprintsBody`）。真实 `KnownHost`：TOFU 信任过的主机密钥记录。
/// 左滑删除（二次确认）：删掉后下次连接该主机会重新走首次信任确认。
struct FingerprintsView: View {
    @Query(sort: [SortDescriptor(\KnownHost.firstTrustedAt, order: .reverse)]) private var hosts: [KnownHost]
    @Environment(\.modelContext) private var context
    @State private var pendingDelete: KnownHost?

    var body: some View {
        Group {
            if hosts.isEmpty {
                MEmptyState(icon: "shield", title: KnownHostCopy.emptyTitle,
                            message: KnownHostCopy.emptyMessage)
            } else {
                list
            }
        }
        .background(M.canvas)
        .navigationTitle("已知主机指纹")
        .navigationBarTitleDisplayMode(.inline)
        .alert(KnownHostCopy.deleteTitle(address: pendingDelete?.displayAddress ?? ""),
               isPresented: deleteBinding,
               presenting: pendingDelete) { host in
            Button("删除", role: .destructive) { delete(host) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text(KnownHostCopy.deleteMessage)
        }
    }

    // List 而不是 MInsetGroup：swipeActions 只在 List 里生效，且 List 本身按需建行（库里可能上千条）。
    private var list: some View {
        List {
            Section {
                ForEach(hosts) { h in
                    MInsetRow(icon: "shield", label: h.displayAddress,
                              sub: "\(h.fingerprint) · \(h.keyTypeLabel)",
                              last: true,
                              trailing: AnyView(
                                Text(h.trustedDateText)
                                    .font(M.mono(12)).foregroundStyle(M.text4)))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(M.card)
                        // 只放图标不带文字；不用 role: .destructive——那会在确认之前就把行乐观地划走。
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { pendingDelete = h } label: { Image(systemName: "trash") }
                                .tint(M.danger)
                                .accessibilityLabel("删除")
                        }
                }
            } header: {
                Text("已知主机 · \(hosts.count)")
            } footer: {
                Text("首次连接或主机密钥变化时，uTerm 会要求你确认指纹后才信任。左滑可删除。")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func delete(_ host: KnownHost) {
        KnownHostLibrary.delete(host, in: context)
        pendingDelete = nil
    }
}

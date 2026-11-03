import SwiftUI
import SwiftData

/// 已知主机指纹（设计稿 `FingerprintsBody`）。真实 `KnownHost`：TOFU 信任过的主机密钥记录。
struct FingerprintsView: View {
    @Query(sort: [SortDescriptor(\KnownHost.firstTrustedAt, order: .reverse)]) private var hosts: [KnownHost]
    @Environment(\.mAccent) private var accent

    var body: some View {
        Group {
            if hosts.isEmpty {
                MEmptyState(icon: "shield", title: "暂无已知主机",
                            message: "首次连接并信任一台主机后，它的密钥指纹会记录在此。")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        MInsetGroup(header: "已知主机 · \(hosts.count)",
                                    footer: "首次连接或主机密钥变化时，uTerm 会要求你确认指纹后才信任。",
                                    lazy: true) {
                            let lastID = hosts.last?.id
                            ForEach(hosts) { h in
                                MInsetRow(icon: "shield", label: h.host,
                                          sub: "\(h.fingerprint) · \(keyTypeLabel(h.keyTypeRaw))",
                                          last: h.id == lastID,
                                          trailing: AnyView(
                                            Text(addedText(h.firstTrustedAt))
                                                .font(M.mono(12)).foregroundStyle(M.text4)))
                            }
                        }
                    }
                    .padding(.top, 12)
                    .mReadableColumn()
                }
            }
        }
        .background(M.canvas)
        .navigationTitle("已知主机指纹")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func keyTypeLabel(_ raw: String) -> String {
        raw.hasPrefix("ssh-") ? String(raw.dropFirst(4)) : raw
    }
    private func addedText(_ date: Date) -> String { UTermFormat.date(date) }
}

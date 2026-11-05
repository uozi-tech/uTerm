import Network
import SwiftUI
import UIKit

/// 打洞诊断：在不同网络下各跑几次，看能不能直连。入口藏在 Mac 那一行的长按菜单里。
struct RemoteICEDiagnosticsView: View {
    let mac: RemoteMacDirectory.Mac
    let directory: RemoteMacDirectory

    @Environment(\.dismiss) private var dismiss
    @AppStorage("remote.iceProbeNote") private var note = ""
    @State private var running = false
    @State private var results: [RemoteICEProbeResult] = []
    private let log = RemoteICEProbeLog(defaults: .standard)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("网络备注，如：移动 5G ↔ 家里电信", text: $note)
                    Button {
                        run()
                    } label: {
                        HStack {
                            Text("开始诊断")
                            if running {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(running)
                } footer: {
                    Text("只测试打洞，不影响现有连接。记录不含 IP 地址，只保存在这台手机上。")
                }
                if !results.isEmpty {
                    Section {
                        Text(successSummary)
                        Button("复制全部结果") {
                            UIPasteboard.general.string = results.map(\.summaryLine).joined(separator: "\n")
                        }
                        Button("清空记录", role: .destructive) {
                            log.clear()
                            results = []
                        }
                    }
                    Section("记录") {
                        ForEach(results) { row($0) }
                    }
                }
            }
            .navigationTitle("打洞诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { results = log.load() }
    }

    private var successSummary: String {
        let connected = results.filter(\.connected).count
        return "成功 \(connected) / \(results.count)"
    }

    private func row(_ result: RemoteICEProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.connected ? "打通" : "没打通：\(result.failure ?? "未知")")
                .foregroundStyle(result.connected ? Color.primary : Color.red)
            Text("\(result.note.isEmpty ? "无备注" : result.note) · \(result.network)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Group {
                if result.connected {
                    Text(connectedDetail(result))
                }
                Text("本机 \(result.localCandidates.joined(separator: " "))")
                Text("Mac \(result.remoteCandidates.joined(separator: " "))")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func connectedDetail(_ result: RemoteICEProbeResult) -> String {
        let roundTrip = result.roundTripMillis.map { String(format: "%.0f ms", $0) } ?? "-"
        return "\(result.selectedLocal ?? "?") → \(result.selectedRemote ?? "?")，"
            + "打通 \(result.connectMillis ?? -1) ms，往返 \(roundTrip)，丢包 \(result.lossPercent ?? -1)%"
    }

    private func run() {
        guard let probe = directory.iceProbeRunner(for: mac) else { return }
        running = true
        let currentNote = note
        Task {
            let network = await Self.currentNetwork()
            var result = await probe.runner.run(mac: probe.peer)
            result.note = currentNote
            result.network = network
            log.append(result)
            results = log.load()
            running = false
        }
    }

    private static func currentNetwork() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                var parts: [String] = []
                if path.usesInterfaceType(.wifi) {
                    parts.append("Wi-Fi")
                } else if path.usesInterfaceType(.cellular) {
                    parts.append("蜂窝")
                } else if path.usesInterfaceType(.wiredEthernet) {
                    parts.append("有线")
                } else {
                    parts.append("其他")
                }
                if path.supportsIPv6 { parts.append("IPv6") }
                continuation.resume(returning: parts.joined(separator: " "))
            }
            monitor.start(queue: DispatchQueue(label: "com.uozi.uTerm.remote.ice-probe.path"))
        }
    }
}

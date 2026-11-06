import SwiftUI

/// 把「正在运行」条挂到标签栏上方：iOS 26.1 起用系统的 `tabViewBottomAccessory`（玻璃底、
/// 随标签栏收起变成行内样式，与「音乐」正在播放同款）；更早的系统浮在标签栏上方。
/// 只在有并行执行会话（在跑，或跑完还没看 / 没划掉）时出现。
struct ParallelRunAccessoryHost: ViewModifier {
    @Environment(MobileStore.self) private var store

    func body(content: Content) -> some View {
        let visible = !store.parallelSessions.isEmpty
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: visible) { ParallelRunAccessory() }
        } else {
            content.overlay(alignment: .bottom) {
                if visible {
                    ParallelRunAccessory()
                        .frame(height: 48)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 58)   // 标签栏之上
                }
            }
        }
    }
}

/// 「正在运行」条：最近一次运行的名字 + 进度，点一下回到全屏页；多于一次时右侧「+N」列出其余；
/// 跑完的可以划掉。
struct ParallelRunAccessory: View {
    @Environment(MobileStore.self) private var store

    var body: some View {
        if let latest = store.parallelSessions.last {
            HStack(spacing: 10) {
                Button { store.showParallel(latest) } label: {
                    HStack(spacing: 10) {
                        Self.statusIcon(latest).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(latest.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(latest.isRunning ? "后台运行中 · \(latest.progressText)" : "已完成 · \(latest.progressText)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("回到这次运行"))

                if store.parallelSessions.count > 1 {
                    MMenu {
                        ForEach(store.parallelSessions.reversed()) { s in
                            Button { store.showParallel(s) } label: {
                                Label("\(s.title) · \(s.progressText)",
                                      systemImage: s.isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            }
                        }
                    } label: {
                        Text("+\(store.parallelSessions.count - 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 32, minHeight: 32)
                    }
                    .accessibilityLabel(Text("其余 \(store.parallelSessions.count - 1) 次运行"))
                }

                if !latest.isRunning {
                    Button { withAnimation(.snappy) { store.removeParallel(latest) } } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("移除这次运行"))
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    static func statusIcon(_ session: ParallelRunSession) -> some View {
        if session.isRunning {
            ProgressView().controlSize(.small)
        } else if (session.controller?.failedCount ?? 0) > 0 {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(M.danger)
        } else {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(M.success)
        }
    }
}

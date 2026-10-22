import UDesignKit
import SwiftUI

/// 窗口右下角的「打开」toast 浮层（短暂出现、可关）。常驻的「正在同步 N 个文件」芯片
/// 不在这里，而在状态栏（`ExternalSyncChip`）——浮层会压住右侧 Agent 输入框 / 检视器按钮。
/// 没有 toast 时整层不占位也不吃点击。
struct ExternalOpenOverlay: View {
    let coordinator: ExternalOpenCoordinator

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(coordinator.toasts) { toast in
                ExternalOpenToastView(toast: toast, coordinator: coordinator)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeOut(duration: 0.18), value: coordinator.toasts)
    }
}

private struct ExternalOpenToastView: View {
    let toast: ExternalOpenCoordinator.Toast
    let coordinator: ExternalOpenCoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(UD.font(12.5, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(2)
                if let detail = toast.detail {
                    Text(detail)
                        .font(UD.font(11.5))
                        .foregroundStyle(UD.text3)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let sessionID = toast.retrySessionID {
                    Button("重试") { coordinator.retry(sessionID) }
                        .buttonStyle(.link)
                        .font(UD.font(11.5, weight: .medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if toast.kind != .progress {
                Button {
                    coordinator.dismissToast(toast.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UD.text4)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background(UD.overlayHi)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UD.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .udShadow(.md)
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.kind {
        case .progress:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(UD.success)
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(UD.accent)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UD.danger)
        }
    }
}

/// 状态栏里的「正在同步 N 个外部编辑的文件」，点开是逐个文件的菜单。没有会话时不显示。
struct ExternalSyncChip: View {
    let coordinator: ExternalOpenCoordinator

    var body: some View {
        if !coordinator.sessions.isEmpty { chip }
    }

    private var chip: some View {
        Menu {
            ForEach(coordinator.sessions) { session in
                Menu {
                    if case .failed = session.state {
                        Button("重新上传") { coordinator.retry(session.id) }
                    }
                    Button("在 Finder 中显示本地副本") { coordinator.revealInFinder(session.id) }
                    Divider()
                    Button("停止同步") { coordinator.stopSync(session.id) }
                } label: {
                    Text("\(session.fileName)  ·  \(stateLabel(session.state))")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasFailure ? "exclamationmark.arrow.triangle.2.circlepath"
                                             : "arrow.triangle.2.circlepath")
                    .foregroundStyle(hasFailure ? UD.danger : UD.accent)
                Text("正在同步 \(coordinator.sessions.count) 个外部编辑的文件")
                    .foregroundStyle(UD.text3)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("用本机应用打开的文件，保存后会自动上传回服务器")
    }

    private var hasFailure: Bool {
        coordinator.sessions.contains {
            if case .failed = $0.state { return true }
            return false
        }
    }

    private func stateLabel(_ state: ExternalOpenCoordinator.SessionState) -> String {
        switch state {
        case .watching:  return "监听中"
        case .uploading: return "上传中…"
        case .failed:    return "上传失败"
        }
    }
}

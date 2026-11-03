#if DEBUG
import SwiftUI
import UIKit
import class SwiftTerm.TerminalView

/// 布局诊断浮层（仅 Debug 构建）：在真机上把系统给的几何原样显示出来，供截图排查。
///
/// iPhone Duo 的状态栏保留区、容器边距、终端 UIScrollView 的内容内边距在真机与 vphone 上
/// 不一定一致，只按 VM 实测写的布局在真机上可能不生效（2026-11-03：真机竖屏标签条没进
/// 状态栏那一行、右格终端内容右移约 100pt）。打开方式：设置 › 长按「版本」一行。
enum MLayoutDiagnostics {
    static let key = "debug.layoutDiagnostics"
}

/// 根视图挂一次：开关打开时在左下角显示诊断文本，每秒刷新。
struct MLayoutDiagnosticsOverlay: View {
    @AppStorage(MLayoutDiagnostics.key) private var enabled = false
    @Environment(\.mChrome) private var chrome
    @Environment(MobileWorkspace.self) private var workspace

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(report)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: MRadius.xs))
                    .padding(.leading, 8)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
    }

    private var report: String {
        var lines: [String] = []
        lines.append("root \(r(chrome.root))")
        lines.append("safe \(e(chrome.safeAreaInsets))")
        lines.append("status \(chrome.statusBar.map(r) ?? "nil")")
        lines.append("raw \(chrome.rawOcclusion.map { "\(r($0.frame))\($0.active ? "" : " (inactive)")" }.joined(separator: "  "))")
        lines.append("container \(e(chrome.containerMargins))")
        lines.append("topBar \(chrome.topBar.map(r) ?? "nil")")
        lines.append("cornerSafeH \(chrome.cornerSafeArea.map(r) ?? "nil")")
        lines.append("row \(chrome.statusRowHeight.map { "\($0)" } ?? "nil")  column \(chrome.statusColumn.map { "\($0.width)/\($0.statusBottom)" } ?? "nil")")
        for (i, tab) in workspace.terminalTabs.enumerated() {
            guard let view = tab.controller.terminalView else { continue }
            let frame = view.window.map { view.convert(view.bounds, to: $0) } ?? .zero
            lines.append("term\(i) frame \(r(frame))")
            lines.append("  inset \(u(view.contentInset)) adj \(u(view.adjustedContentInset))")
            lines.append("  safe \(u(view.safeAreaInsets)) offset (\(Int(view.contentOffset.x)),\(Int(view.contentOffset.y)))")
        }
        return lines.joined(separator: "\n")
    }

    private func r(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
    private func e(_ i: EdgeInsets) -> String {
        "t\(Int(i.top)) l\(Int(i.leading)) b\(Int(i.bottom)) r\(Int(i.trailing))"
    }
    private func u(_ i: UIEdgeInsets) -> String {
        "t\(Int(i.top)) l\(Int(i.left)) b\(Int(i.bottom)) r\(Int(i.right))"
    }
}
#endif

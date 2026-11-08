import AppKit
import SwiftUI

// MARK: - 主列表键位映射（纯函数，便于单测）

/// Welcome 主机列表的键盘动作。`WelcomeKeymap.listAction` 把一次 keyDown 归类成这些动作之一。
nonisolated enum WelcomeListKey: Equatable, Sendable {
    case prev          // ↑ 上一台
    case next          // ↓ 下一台
    case first         // ⌘↑ 第一台
    case last          // ⌘↓ 最后一台
    case edit          // ⌘E 编辑选中
    case delete        // ⌘⌫ 删除选中
    case duplicate     // ⌘D 复制选中主机为新服务器（预填新建表单）
}

/// 把一次按键（已拆成 keyCode / 字符 / 修饰键 / 是否在文本编辑）映射成主机列表动作。
///
/// 纯函数、无副作用——所有 `event.window === key` / 面板开关等上下文判断留给调用方
/// （`WelcomeView.handleListKey`），这里只做「键 → 语义」翻译，方便 `WelcomeKeymapTests` 覆盖。
nonisolated enum WelcomeKeymap {
    // macOS 虚拟键码（HIToolbox `Events.h`）。
    private static let upArrow: UInt16 = 126
    private static let downArrow: UInt16 = 125
    private static let deleteKey: UInt16 = 51   // ⌫ backspace

    static func listAction(keyCode: UInt16,
                           chars: String,
                           command: Bool,
                           option: Bool,
                           control: Bool,
                           isTextEditing: Bool) -> WelcomeListKey? {
        // 带 ⌥ / ⌃ 的组合留给侧栏（⌥↑↓）或系统，主列表一概不接。
        if option || control { return nil }

        if command {
            switch keyCode {
            case upArrow:   return .first
            case downArrow: return .last
            // 文本编辑态下 ⌘⌫ = 删到行首，必须放行，绝不当成「删服务器」。
            case deleteKey: return isTextEditing ? nil : .delete
            default: break
            }
            switch chars {
            case "e": return .edit
            // ⌘D 复制为新服务器；文本编辑态下放行（不抢输入框）。
            case "d": return isTextEditing ? nil : .duplicate
            default:  return nil
            }
        }

        // 裸方向键（含 fn / numericPad 标志，故只判 command/option/control）：移动选中。
        switch keyCode {
        case upArrow:   return .prev
        case downArrow: return .next
        default:        return nil
        }
    }
}

// MARK: - 侧栏可导航条目顺序（纯函数，便于单测）

/// 侧栏一个可键盘跳转的目标：某个主机分区，或「快捷命令」/「我的 Mac」面板。
nonisolated enum WelcomeNavTarget: Hashable, Sendable {
    case section(NavSection)
    case quickCommands
    case remoteMacs
}

/// 侧栏 ⌘1…⌘9 / ⌥↑↓ 的条目顺序——必须与 `WelcomeSidebar.body` 渲染顺序逐项对齐，
/// 否则数字提示与实际跳转会错位。抽成纯函数以便单测锁定顺序。
nonisolated enum WelcomeSidebarNav {
    static func entries(pinnedCount: Int,
                        recentCount: Int,
                        showsGroupSection: Bool,
                        groupNames: [String],
                        ungroupedCount: Int) -> [WelcomeNavTarget] {
        var result: [WelcomeNavTarget] = []
        if pinnedCount > 0 { result.append(.section(.pinned)) }
        if recentCount > 0 { result.append(.section(.recent)) }
        if showsGroupSection { result.append(.section(.allHosts)) }
        for name in groupNames { result.append(.section(.group(name))) }
        if ungroupedCount > 0 { result.append(.section(.ungrouped)) }
        result.append(.quickCommands)
        result.append(.remoteMacs)
        return result
    }

    /// 第 `target` 项的 ⌘ 数字提示（"⌘1"…"⌘9"）；超过 9 项或不在表内返回 nil。
    static func shortcutHint(for target: WelcomeNavTarget, in entries: [WelcomeNavTarget]) -> String? {
        guard let idx = entries.firstIndex(of: target), idx < 9 else { return nil }
        return "⌘\(idx + 1)"
    }
}

// MARK: - 窗口级 keyDown 监听

/// 给 Welcome 窗口装一个本地 keyDown monitor，把事件交给 `handle` 决定是否消费。
/// 结构对齐 `WorkspaceCloseShortcutInstaller`：本地监听、handler 即主线程上下文、
/// 只让本窗口（key window）的事件生效——sheet（编辑表单等）是独立子窗口，天然被排除。
struct WelcomeKeyboardMonitor: NSViewRepresentable {
    /// 返回 true 表示已处理并消费该事件（吞掉，不再下发）。
    let handle: @MainActor (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView(handle) }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handle = handle
    }

    final class MonitorView: NSView {
        var handle: @MainActor (NSEvent) -> Bool
        // 只在主线程读写；让 deinit / viewDidMoveToWindow 都能安全 removeMonitor。
        private nonisolated(unsafe) var monitor: Any?

        init(_ handle: @escaping @MainActor (NSEvent) -> Bool) {
            self.handle = handle
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // handler 即主线程上下文（与 WorkspaceCloseShortcut 同款，直接访问 self / 调 @MainActor handle）。
                    guard let self, let win = self.window, event.window === win else { return event }
                    return self.handle(event) ? nil : event
                }
            } else {
                removeMonitor()
            }
        }

        private nonisolated func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}

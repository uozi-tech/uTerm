#if DEBUG
import SwiftData
import SwiftUI

/// 调试：启动参数 `-LiveActivityDebugDemo YES` 时开一个演示终端标签页，按时间表报程序状态（OSC 7501），
/// 真机上不连主机也能看灵动岛 / 锁屏、量进后台之后多久暂停（日志分类 `live-activity`）。只在 Debug 构建里有。
/// 值写 `keep` 时连上之后顺带开「离开后继续运行」15 分钟（等于替用户点了菜单）。
///
/// 时间表（从连上起算，循环）：0 s 运行中 → 20 s 等待确认 → 35 s 运行中 → 50 s 完成 → 70 s 重来。
enum TerminalActivityDemo {
    private static var mode: String? {
        guard let value = UserDefaults.standard.string(forKey: DefaultsKey.liveActivityDebugDemo)?.lowercased(),
              !["", "0", "no", "false"].contains(value) else { return nil }
        return value
    }
    static var isRequested: Bool { mode != nil }

    static func open(in workspace: MobileWorkspace, store: MobileStore, container: ModelContainer,
                     center: TerminalActivityCenter) {
        guard isRequested, workspace.isEmpty else { return }
        let host = ServerProfile()
        host.name = "demo-host"
        // 值写 `scroll`：不报程序状态，一上来灌 3000 行带编号的回滚，真机上只拿来试滚动手感。
        let scrollOnly = mode == "scroll"
        let tab = TermTab(host: host, transportFactory: MobileTerminalTransportFactory { _ in
            scrollOnly ? ScrollBackend() as any TerminalBackend : DemoBackend()
        })
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        workspace.open(.terminal(tab))
        store.showWorkspace = true
        if mode == "keep" {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let ok = center.keepAlive.start(minutes: 15)
                FileHandle.standardError.write(Data("[live-activity] demo keep-alive submitted=\(ok)\n".utf8))
            }
        }
    }

    /// 一次灌 3000 行回滚，之后静止：每行带编号、隔行换色，十行一条亮行，滚动时好看出有没有跳、有没有往回。
    private actor ScrollBackend: TerminalBackend {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        private let output: AsyncStream<TerminalOutputItem>.Continuation

        init() {
            var out: AsyncStream<TerminalOutputItem>.Continuation!
            outputItems = AsyncStream { out = $0 }
            output = out
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {
            var text = ""
            for line in 1 ... 3000 {
                let number = String(format: "%04d", line)
                // 每行开头 7 格是行号的二进制条码（第 j 格 = 第 j 位，█ = 1）：真手录制时从出的每一帧画面里读回滚到了哪
                //（`GhosttyScrollPresentProbe`，和测试里的 `GhosttyOnScreenScrollTests.BarcodeDecoder` 同一套编码）。
                let code = (0 ..< 7).map { (line >> $0) & 1 == 1 ? "█" : " " }.joined()
                if line % 10 == 0 {
                    text += "\(code)  \u{1b}[1;30;43m \(number) ──────────── row \(number) ──────────── \u{1b}[0m\r\n"
                } else {
                    let color = line % 2 == 0 ? 36 : 37
                    text += "\(code)  \u{1b}[\(color)m\(number)\u{1b}[0m  the quick brown fox jumps over the lazy dog \(number)\r\n"
                }
            }
            text += "\u{1b}[32m-- end of scrollback test (3000 lines) --\u{1b}[0m\r\n"
            output.yield(.bytes(Data(text.utf8)))
        }

        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
    }

    private actor DemoBackend: TerminalBackend {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        private let output: AsyncStream<TerminalOutputItem>.Continuation
        private var task: Task<Void, Never>?

        init() {
            var out: AsyncStream<TerminalOutputItem>.Continuation!
            outputItems = AsyncStream { out = $0 }
            output = out
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {
            let output = output
            task = Task {
                let script: [(TimeInterval, String)] = [
                    (0, "state=working:app=claude-code"),
                    (20, "state=blocked:app=claude-code:kind=permission"),
                    (35, "state=working:app=claude-code"),
                    (50, "state=done:app=claude-code"),
                ]
                var cycle = 0
                while !Task.isCancelled {
                    let start = Date()
                    for (at, payload) in script {
                        let wait = at - Date().timeIntervalSince(start)
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                        let text = "demo cycle \(cycle) t=\(Int(at)) \(payload)\r\n\u{1b}]7501;\(payload)\u{1b}\\"
                        output.yield(.bytes(Data(text.utf8)))
                    }
                    try? await Task.sleep(for: .seconds(20))
                    cycle += 1
                }
            }
        }

        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async { task?.cancel() }
    }
}
#endif

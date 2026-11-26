import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 锁屏上的实时活动最高约 160pt（Apple 的上限），内容比它高时系统把整块居中裁掉：
/// 标题行切掉上半、「还有 N 个」切掉下半（2026-11-26 真机截图）。这里把锁屏视图按真实字号排一遍，量它要多高。
@MainActor
final class TerminalActivityLockScreenLayoutTests: XCTestCase {
    /// 系统给锁屏实时活动的最大高度。
    private let maxHeight: CGFloat = 160
    /// 锁屏卡片的宽度：小屏手机竖屏到 Duo 横屏。
    private let widths: [CGFloat] = [320, 343, 361, 400, 680]

    private func row(_ title: String, host: String?, program: String, status: String,
                     tone: TerminalActivityAttributes.Tone) -> TerminalActivityAttributes.Row {
        .init(id: UUID(), title: title, host: host, program: program, status: status,
              shortStatus: status, tone: tone, since: Date(timeIntervalSinceNow: -540))
    }

    private func state(rows: Int, detail: Bool, overflow: Int, keeping: Bool) -> TerminalActivityAttributes.ContentState {
        let all = [
            row("iOS 终端窗口重绘闪烁", host: detail ? "Jacky 的 MacBook Pro" : nil, program: "Claude Code",
                status: "运行中", tone: .working),
            row("ios-app-store-subscription", host: detail ? "prod-1" : nil, program: "Codex",
                status: "等待确认", tone: .attention),
            row("Code 视图侧边栏与 Desktop 差异", host: detail ? "staging" : nil, program: "Claude Code",
                status: "运行中", tone: .working),
        ]
        return .init(rows: Array(all.prefix(rows)),
                     overflow: overflow,
                     overflowText: overflow > 0 ? "还有 \(overflow) 个" : nil,
                     keepUntil: keeping ? Date(timeIntervalSinceNow: 600) : nil,
                     paused: false,
                     footer: keeping ? "后台保持中，还剩" : nil,
                     pausedText: "已暂停，回到 uTerm 查看最新状态",
                     sharedProgram: detail ? nil : "Claude Code",
                     sharedStatus: detail ? nil : "运行中",
                     sharedHost: detail ? nil : "Jacky 的 MacBook Pro")
    }

    private func height(of state: TerminalActivityAttributes.ContentState, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: TerminalLockScreenView(state: state))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// 截图里的情形：3 行、每行都有第二行说明、底下「还有 2 个」。
    func testScreenshotCaseFits() {
        let s = state(rows: 3, detail: true, overflow: 2, keeping: false)
        for width in widths {
            XCTAssertLessThanOrEqual(height(of: s, width: width), maxHeight, "宽 \(width)")
        }
    }

    /// 所有组合都不能超高：行数、有没有说明行、有没有「还有 N 个」、有没有后台保持的底行。
    func testEveryCombinationFits() {
        for rows in 1...3 {
            for detail in [false, true] {
                for overflow in [0, 2] {
                    for keeping in [false, true] {
                        let s = state(rows: rows, detail: detail, overflow: overflow, keeping: keeping)
                        for width in widths {
                            XCTAssertLessThanOrEqual(height(of: s, width: width), maxHeight,
                                                     "rows=\(rows) detail=\(detail) overflow=\(overflow) keeping=\(keeping) 宽 \(width)")
                        }
                    }
                }
            }
        }
    }

    /// 放得下的时候（两行以内）仍然用两行的排法，说明写在标题下面，不挤到同一行。
    func testFewRowsKeepDetailLine() {
        let s = state(rows: 2, detail: true, overflow: 0, keeping: false)
        let one = state(rows: 2, detail: false, overflow: 0, keeping: false)
        XCTAssertGreaterThan(height(of: s, width: 361), height(of: one, width: 361) + 20,
                             "两行以内带说明时应比不带说明高出一整行")
    }
}

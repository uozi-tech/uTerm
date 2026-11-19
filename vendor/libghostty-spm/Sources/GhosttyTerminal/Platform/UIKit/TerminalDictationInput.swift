//
//  TerminalDictationInput.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    /// uTerm 本地补丁：这次上屏的字是不是听写给的一版识别结果。
    ///
    /// 听写的第一版落在光标处（空范围），UIKit 的 `UIKBInputDelegateManager` 碰到空范围不调
    /// `replace(_:withText:)`，改调 `insertText(_:)`（iOS 27.2 反汇编：`replaceRange:oldText:withText:forReplaceAction:`
    /// 的听写分支，范围空就 `insertText:`；Duo 真机日志里听写的第一个字也是从 `insertText` 进来的）。
    /// 这一版必须记进 `TerminalCommittedTail`，否则第二版找不到它、听写被取消，只剩第一个字。
    ///
    /// 光看 `insertText` 分不出听写和打字。公开的 `UITextInputContext.isDictationInputExpected` 在那一刻读到的是
    /// false（UIKit 把来源设在它自己的私有输入代理上，真机实测），能用的是插字前同步发出的
    /// `UIDictationWillInsertHypothesisNotification`（`-[UIDictationController _updateLastHypothesis:WithNewHypothesis:]`
    /// 发完它就去替换，中间只读一次选区）。收到通知记一个标记，下一次上屏认领它；没人认领的话这一轮主线程结束就作废，
    /// 不会漏到之后的打字里。通知名是私有的：哪天改了名，退回成以前的样子（听写只出第一版），不影响打字。
    public enum TerminalDictationInput {
        public static let willInsertHypothesis = Notification.Name("UIDictationWillInsertHypothesisNotification")

        @MainActor private static var observer: (any NSObjectProtocol)?
        @MainActor private static var pendingHypothesis = false

        /// 开始收通知。可以反复调，只装一次。要在听写开始之前调（输入视图建好时）。
        @MainActor
        public static func startObserving() {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: willInsertHypothesis,
                object: nil,
                queue: nil,
            ) { _ in
                // UIKit 在主线程上发；不在主线程就赶不上紧跟着的那次插字，不管它。
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { markHypothesis() }
            }
        }

        /// 记下「接下来那次上屏是听写的一版」。测试里代替真的通知。
        @MainActor
        public static func markHypothesis() {
            pendingHypothesis = true
            DispatchQueue.main.async { pendingHypothesis = false }
        }

        /// 认领标记：返回这次上屏是不是听写的一版，同时清掉标记。
        @MainActor
        public static func claimHypothesis() -> Bool {
            defer { pendingHypothesis = false }
            return pendingHypothesis
        }
    }
#endif

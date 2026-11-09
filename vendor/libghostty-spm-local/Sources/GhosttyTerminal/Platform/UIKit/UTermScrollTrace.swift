//
//  UTermScrollTrace.swift
//  uTerm 本地补丁（不在上游）：滚动 / 惯性 / 吸附 / 回弹每一步发出了什么，给真机回归测试逐帧读。
//  关着时（默认）`record` 直接返回，不占开销。
//

import Foundation
import QuartzCore

public enum UTermScrollTrace {
    public struct Event: Sendable {
        /// `CACurrentMediaTime()`。
        public let time: Double
        /// momentum / snap / overscroll / drag / row
        public let kind: String
        /// momentum、snap、drag：这一步发出的像素；overscroll：显示的回弹像素；row：视口首行行号。
        public let value: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [Event] = []
    nonisolated(unsafe) private static var enabled = false

    public static var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; events.removeAll(); lock.unlock() }
    }

    static func record(_ kind: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        events.append(Event(time: CACurrentMediaTime(), kind: kind, value: value))
    }

    /// 取出并清空。
    public static func drain() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll()
        return out
    }
}

import AppKit
import SwiftUI
import XCTest

/// 让 SwiftUI 在测试宿主里生成无障碍树。
///
/// `NSHostingView` 的树是懒的：要有辅助功能客户端（VoiceOver、辅助功能检查器、computer-use 这类）连上，
/// 或者 app 被设了 `AXEnhancedUserInterface`，才有子节点；否则 `accessibilityChildren` 一直是空的。
/// 所以这批断言以前只在恰好有客户端连着的机器上才过，命令行跑全是「AX 树里找不到」。
///
/// 只给按 AX 树断言的用例开：开着树 SwiftUI 每次更新都要多维护一份，性能探针的读数不能带上它。
@MainActor
enum AccessibilityTreeForTests {
    private static let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    static func enable(for testCase: XCTestCase) {
        setEnhancedUserInterface(true)
        testCase.addTeardownBlock { @MainActor in
            setEnhancedUserInterface(false)
        }
    }

    /// `AXEnhancedUserInterface` 是私有属性，NSAccessibility 协议里没有它的 setter，只能走老式的
    /// `accessibilitySetValue(_:forAttribute:)`（macOS 10.10 起标废弃）。经 ObjC 运行时调，免编译期废弃警告。
    private static func setEnhancedUserInterface(_ on: Bool) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = NSApp.perform(selector, with: NSNumber(value: on), with: attribute.rawValue as NSString)
    }

    /// 元素的标准 AX 动作名（AXPress / AXScrollToVisible…），只用于诊断输出。
    /// 协议版接口只有逐个动作的方法、没有「列出全部」，老式 `accessibilityActionNames()` 已废弃，同样经运行时调。
    static func legacyActionNames(of element: AnyObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityActionNames")
        guard element.responds(to: selector) else { return [] }
        return element.perform(selector)?.takeUnretainedValue() as? [String] ?? []
    }
}

@MainActor
final class AccessibilityTreeForTestsTests: XCTestCase {

    private func nodeCount() async throws -> Int {
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200))
        let host = NSHostingView(rootView: Button("按钮") {}.frame(width: 300, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = host
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        return host.accessibilityChildren()?.count ?? 0
    }

    /// 这条红了，其他 AX 契约用例的失败就都不用看了：先看树还开不开得出来。
    func testEnablingProducesATree() async throws {
        AccessibilityTreeForTests.enable(for: self)
        let count = try await nodeCount()
        XCTAssertGreaterThan(count, 0)
    }
}

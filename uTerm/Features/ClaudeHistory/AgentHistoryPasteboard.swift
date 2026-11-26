#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 历史会话里的「拷贝」（会话 ID、对话文字），两端共用。
enum AgentHistoryPasteboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

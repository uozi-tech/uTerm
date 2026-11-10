import Foundation
@testable import uTerm

extension TerminalSession {
    /// 当作后端输出喂一段文字：和正式路径同一条链（影子终端 → 事件 → 画面），只是不等输出泵的节拍，
    /// 返回时影子终端已经解析完、事件已经处理完。
    func feedOutput(text: String) {
        receiveOutputForTesting(Data(text.utf8))
    }
}

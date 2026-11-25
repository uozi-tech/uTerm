import Foundation

/// Code 标签页里一个会话的程序退出时怎么收尾（两端共用一条规则）：
///
/// - 有对话记录可看的（对上了记录、那份记录列表里会列出来）：结束终端，回到那份记录（重新读到最新）；
/// - 没有的（新开了没说话就退出、记录没写出来或者是空的）：终端留着最后的画面，顶上「会话已结束」，带「重新开始」「关闭」，
///   不自己跳走——跳回空的「新会话」页就像会话丢了；
/// - 跑了不到 `quickExit` 就退出的也留着（多半是报错：命令没找到、目录不在了），看完了再回到记录。Mac 没有这一条（0）。
nonisolated enum CodeRunExitPolicy {
    static func keepsTerminal(hasListedRecord: Bool, ranFor: TimeInterval, quickExit: TimeInterval) -> Bool {
        !hasListedRecord || ranFor < quickExit
    }
}

import Foundation

/// 远控终端标签的来源：经哪台 Mac、接入它上面的哪个终端。直连 SSH 的标签没有这个。
struct MRemoteSource: Equatable {
    let client: RemoteMacClient
    let sessionID: UUID

    var macName: String { client.macName }

    static func == (lhs: MRemoteSource, rhs: MRemoteSource) -> Bool {
        lhs.client === rhs.client && lhs.sessionID == rhs.sessionID
    }
}

/// 一次「接管这台 Mac」的请求：把它上面的全部终端开成标签，等工作区消费。
struct MRemoteTakeover: Equatable {
    let client: RemoteMacClient
    /// 要接入的全部终端，按 Mac 上的顺序。
    let sessionIDs: [UUID]
    /// 放到前台的那个，连接中页跟踪它。
    let focus: UUID
    /// 让同样内容的连续请求也能被 `onChange` 看到。
    let token = UUID()

    static func == (lhs: MRemoteTakeover, rhs: MRemoteTakeover) -> Bool { lhs.token == rhs.token }
}

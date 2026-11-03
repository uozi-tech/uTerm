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

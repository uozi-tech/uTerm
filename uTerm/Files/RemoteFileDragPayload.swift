import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// SFTP 远端文件行拖拽载荷。仅用于本进程内服务器侧移动；拖到 Finder
    /// 另走同一个 item provider 上注册的 file representation。
    nonisolated static let utermRemoteFile = UTType(exportedAs: "com.uozi.uterm.remote-file")
}

nonisolated struct RemoteFileDragItem: Codable, Equatable, Sendable {
    let scopeID: UUID
    let path: String
    let name: String
    let isDirectory: Bool
}

nonisolated enum RemoteFileDragPayload {
    static func itemProvider(item: RemoteFileDragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(item)) ?? Data()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utermRemoteFile.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func load(from provider: NSItemProvider,
                     completion: @escaping @Sendable (RemoteFileDragItem?) -> Void) {
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utermRemoteFile.identifier
        ) { data, _ in
            guard let data,
                  let item = try? JSONDecoder().decode(RemoteFileDragItem.self, from: data) else {
                completion(nil)
                return
            }
            completion(item)
        }
    }
}

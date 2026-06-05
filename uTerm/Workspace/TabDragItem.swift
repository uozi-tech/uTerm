import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// 标签拖拽载荷的专属类型。仅用于应用内拖拽。
    nonisolated static let utermTabID = UTType(exportedAs: "com.uozi.uterm.tab-id")
}

/// 把标签 id 装进 / 取出 `NSItemProvider`，供 tab 重排与拖到 pane 分屏共用。
nonisolated enum TabDragPayload {
    static func itemProvider(tabID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utermTabID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(tabID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    static func load(from provider: NSItemProvider,
                     completion: @escaping @Sendable (UUID?) -> Void) {
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utermTabID.identifier
        ) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(UUID(uuidString: string))
        }
    }
}

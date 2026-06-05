import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// 文件预览 tab 拖拽载荷的专属类型。仅用于应用内拖拽。
    nonisolated static let utermFileBufferID = UTType(
        exportedAs: "com.uozi.uterm.file-buffer-id")
}

/// 把文件 buffer id 装进 / 取出 `NSItemProvider`。
nonisolated enum FileBufferDragPayload {
    static func itemProvider(bufferID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utermFileBufferID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(bufferID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    static func load(from provider: NSItemProvider,
                     completion: @escaping @Sendable (UUID?) -> Void) {
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utermFileBufferID.identifier
        ) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(UUID(uuidString: string))
        }
    }
}

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// 窗格拖拽载荷的专属类型。用专属类型而非 `.plainText`，避免被
    /// 接受文本拖放的 SwiftTerm 终端 NSView 拦截当成粘贴。仅用于应用内
    /// 拖拽（`NSItemProvider` 注册时已限制 `.ownProcess` 可见性）。
    ///
    /// 使用 `exportedAs:` 必须同时在 `Info.plist` 的
    /// `UTExportedTypeDeclarations` 里登记同名标识，否则 LaunchServices
    /// 会在运行时打印 "expected to be declared and exported" 警告。
    nonisolated static let utermPaneID = UTType(exportedAs: "com.uozi.uterm.pane-id")
}

/// 把窗格 id 装进 / 取出 `NSItemProvider`，用专属 UTType `utermPaneID`。
/// `DropDelegate` 走的是 `NSItemProvider` API，故不用 `Transferable`。
nonisolated enum PaneDragPayload {
    /// 构造一个携带窗格 id 的 item provider，供窗格头部 `.onDrag` 返回。
    static func itemProvider(paneID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utermPaneID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(paneID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// 从 item provider 异步取回窗格 id；解析失败时回调 nil。
    static func load(from provider: NSItemProvider,
                     completion: @escaping @Sendable (UUID?) -> Void) {
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utermPaneID.identifier
        ) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(UUID(uuidString: string))
        }
    }
}

import AppKit
import SwiftUI
import UDesignKit

nonisolated enum PreviewTabCloseScope {
    case selected
    case others
    case tabsToRight
    case all
}

/// 根据右键命中的标签和当前顺序生成关闭队列。保持为纯值逻辑，便于覆盖边界条件，
/// 具体关闭仍交给上层的未保存确认流程。
nonisolated enum PreviewTabMenuPlanner {
    static func closeTargets(
        for scope: PreviewTabCloseScope,
        targetID: UUID,
        orderedIDs: [UUID]
    ) -> [UUID] {
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return [] }

        switch scope {
        case .selected:
            return [targetID]
        case .others:
            return orderedIDs.filter { $0 != targetID }
        case .tabsToRight:
            let nextIndex = orderedIDs.index(after: targetIndex)
            return Array(orderedIDs[nextIndex...])
        case .all:
            return orderedIDs
        }
    }
}

/// 预览标签 chip 的右键菜单。标签条本体现在由共享组件 `UPaneGroupArea` 画，
/// 这里只提供它的 `tabMenu` 闭包内容。
///
/// **这里的 id 全部是标签 id，不是 buffer id** —— 同一个文件可以在两个组里各有一个
/// 标签，关的是标签而不是文档。
struct PreviewTabContextMenu: View {
    let buffer: FileBuffer
    let isTransient: Bool
    let targetTabID: UUID
    /// 本组的标签顺序（「关闭其他 / 关闭右侧」的作用域）。
    let orderedTabIDs: [UUID]
    let onKeepOpen: () -> Void
    let onRequestClose: (UUID) -> Void

    var body: some View {
        if isTransient {
            Button(action: onKeepOpen) {
                Label("保留标签页", systemImage: "pin")
            }
            Divider()
        }

        Button { close(.selected) } label: {
            Label("关闭", systemImage: "xmark")
        }
        Button { close(.others) } label: {
            Label("关闭其他标签页", systemImage: "xmark.square")
        }
        .disabled(targets(for: .others).isEmpty)
        Button { close(.tabsToRight) } label: {
            Label("关闭右侧标签页", systemImage: "arrow.right.to.line")
        }
        .disabled(targets(for: .tabsToRight).isEmpty)
        Button { close(.all) } label: {
            Label("关闭所有标签页", systemImage: "xmark.rectangle")
        }

        Divider()

        // 与文件右键同一套叫法（`RemoteFileAction`）；标签本身就是「预览」，这里不再重复。
        Button {
            RemoteFileCommand.open(path: buffer.remotePath, route: .preferred).post()
        } label: {
            Label(RemoteFileAction.open.title, systemImage: RemoteFileAction.open.systemImage)
        }
        OpenWithMenu(path: buffer.remotePath) { route in
            RemoteFileCommand.open(path: buffer.remotePath, route: route).post()
        }
        Button {
            RemoteFileCommand.download(path: buffer.remotePath, size: buffer.byteSize).post()
        } label: {
            Label(RemoteFileAction.download.title, systemImage: RemoteFileAction.download.systemImage)
        }

        Divider()

        Button { Self.copy(buffer.displayName) } label: {
            Label("拷贝文件名", systemImage: "doc.on.clipboard")
        }
        Button { Self.copy(buffer.remotePath) } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }
    }

    private func targets(for scope: PreviewTabCloseScope) -> [UUID] {
        PreviewTabMenuPlanner.closeTargets(
            for: scope,
            targetID: targetTabID,
            orderedIDs: orderedTabIDs)
    }

    private func close(_ scope: PreviewTabCloseScope) {
        for id in targets(for: scope) {
            onRequestClose(id)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

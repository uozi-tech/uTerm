import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Shared drag source/drop target for reordering custom server groups.
/// The caller owns the ordered list and persists the final position.
struct GroupRowDragModifier: ViewModifier {
    let enabled: Bool
    let groupID: PersistentIdentifier
    @Binding var draggingID: PersistentIdentifier?
    let onMove: (PersistentIdentifier, PersistentIdentifier) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggingID = groupID
                    return NSItemProvider(object: "group" as NSString)
                }
                .onDrop(of: [.text], delegate: GroupReorderDropDelegate(
                    targetID: groupID,
                    draggingID: $draggingID,
                    onMove: onMove
                ))
        } else {
            content
        }
    }
}

/// Moves the dragged group to the target row as soon as the drag enters it.
struct GroupReorderDropDelegate: DropDelegate {
    let targetID: PersistentIdentifier
    @Binding var draggingID: PersistentIdentifier?
    let onMove: (PersistentIdentifier, PersistentIdentifier) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = draggingID, from != targetID else { return }
        onMove(from, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

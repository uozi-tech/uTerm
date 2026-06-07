import Foundation

/// Workspace-wide drag source used to make pane drops synchronous.
/// `NSItemProvider` remains the system-level type-negotiation payload, but the
/// actual in-process source identity lives here so the drop path does not rely
/// on an asynchronous provider load after AppKit finishes the drag session.
nonisolated enum WorkspaceDragSource: Equatable, Sendable {
    case pane(UUID)
    case tab(UUID)
    case fileBuffer(UUID)
}

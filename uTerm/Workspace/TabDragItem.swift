import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 标签拖拽的传输载荷。仅在应用内拖拽。
struct TabDragItem: Codable, Transferable, Sendable {
    let tabID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

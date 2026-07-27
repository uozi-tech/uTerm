nonisolated enum WorkspaceRemoteFileOpenGate {
    enum Decision: Equatable {
        case openDirectly
        case confirmLargeFile
        case block
    }

    static let confirmationThreshold: Int64 = 5 * 1024 * 1024
    static let blockThreshold: Int64 = 50 * 1024 * 1024

    /// 未知大小只跳过提示门，不跳过实际安全边界；FilePreviewModel 会在流内强制
    /// 执行 50 MB 上限。
    static func decision(forSize size: Int64?) -> Decision {
        guard let size else { return .openDirectly }
        if size > blockThreshold {
            return .block
        }
        if size > confirmationThreshold {
            return .confirmLargeFile
        }
        return .openDirectly
    }
}

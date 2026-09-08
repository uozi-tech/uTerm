nonisolated enum WorkspaceRemoteFileOpenGate {
    enum Decision: Equatable {
        case openDirectly
        case confirmLargeFile
        case block
        /// 归档/可执行/媒体等本就不该进编辑器的类型（携带命中的扩展名，供文案用）。
        case unsupportedType(ext: String)
    }

    static let confirmationThreshold: Int64 = 5 * 1024 * 1024
    static let blockThreshold: Int64 = 50 * 1024 * 1024

    /// 类型判据排在大小判据**前面**：191 MB 的 `.tar.gz` 该说「这类文件不支持」，
    /// 说「超过 50 MB 上限」是把用户往「那我找个小点的压缩包」的错路上带。
    ///
    /// 未知大小只跳过提示门，不跳过实际安全边界；FilePreviewModel 会在流内强制
    /// 执行 50 MB 上限。
    static func decision(forPath path: String, size: Int64?) -> Decision {
        if let ext = PreviewFileType.blockedExtension(forPath: path) {
            return .unsupportedType(ext: ext)
        }
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

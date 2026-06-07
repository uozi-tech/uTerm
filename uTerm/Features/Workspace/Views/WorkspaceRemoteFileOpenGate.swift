nonisolated enum WorkspaceRemoteFileOpenGate {
    enum Decision: Equatable {
        case openDirectly
        case confirmLargeFile
        case block
    }

    static let confirmationThreshold: Int64 = 5 * 1024 * 1024
    static let blockThreshold: Int64 = 50 * 1024 * 1024

    static func decision(forSize size: Int64) -> Decision {
        if size > blockThreshold {
            return .block
        }
        if size > confirmationThreshold {
            return .confirmLargeFile
        }
        return .openDirectly
    }
}

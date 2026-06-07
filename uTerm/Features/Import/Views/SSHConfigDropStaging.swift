import Foundation

/// 拖拽导入的文件 staging 辅助：把拖入项拷进容器、定位 config。
/// 纯函数（基于真实临时目录，无钥匙串/无 GUI，可单测）。
nonisolated enum SSHConfigDropStaging {
    /// 把 source 拷贝进全新目录 root 下，返回拷贝件 URL。目录递归拷。
    /// 调用方负责用完后删除 root。
    static func stage(source: URL, intoRoot root: URL,
                      fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: source, to: dest)
        return dest
    }

    /// 给定 staging 里的拷贝件，定位「要读的 config」与「读私钥用的 dir」。
    /// 目录 → (item/config, item)（config 须存在，否则 nil）；文件 → (item, 父目录)。
    static func locateConfig(in stagedItem: URL,
                             fileManager: FileManager = .default) -> (config: URL, dir: URL)? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: stagedItem.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            let config = stagedItem.appendingPathComponent("config")
            var configIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: config.path, isDirectory: &configIsDir),
                  !configIsDir.boolValue else { return nil }
            return (config, stagedItem)
        } else {
            return (stagedItem, stagedItem.deletingLastPathComponent())
        }
    }
}

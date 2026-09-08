import Foundation

/// 把远程文件暂存后交给外部应用打开。
///
/// 每次使用独立的 0700 随机目录与 0600 文件，避免把远程内容写进可预测的
/// `tmp/<basename>`（同名覆盖、符号链接跟随、不同服务器互相覆盖）。
nonisolated enum ExternalFileStager {
    static func stage(
        data: Data,
        suggestedName: String,
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let destination = try prepareDestination(suggestedName: suggestedName,
                                                 rootDirectory: rootDirectory)
        try data.write(to: destination, options: .atomic)
        try restrictPermissions(at: destination)
        return destination
    }

    /// 只备好目标路径（0700 私有目录 + 清洗过的文件名），内容由调用方**流式**写入。
    /// 归档/媒体这类只能外部打开的文件动辄上百 MB，先 `Data` 到内存再落盘不可行。
    static func prepareDestination(
        suggestedName: String,
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let manager = FileManager.default
        let directory = rootDirectory
            .appendingPathComponent("uterm-external-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700],
                                  ofItemAtPath: directory.path)
        return directory.appendingPathComponent(
            sanitizedFileName(suggestedName), isDirectory: false)
    }

    /// 内容落盘后收紧到 0600（流式写入的实现走同目录临时文件 + rename，权限得自己压）。
    static func restrictPermissions(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    static func sanitizedFileName(_ suggestedName: String) -> String {
        let leaf = (suggestedName as NSString).lastPathComponent
        let sanitized = String(leaf.map { character -> Character in
            let unsafe = character == "/" || character == "\\" ||
                character.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            return unsafe ? "_" : character
        }).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            return "download"
        }
        return sanitized
    }
}

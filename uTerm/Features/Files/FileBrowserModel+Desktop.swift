import Foundation
import UniformTypeIdentifiers

/// `FileBrowserModel` 的 macOS 专属部分：远程条目拖出到 Finder / 拖到别的目录，
/// 以及交给「外部打开」的主机描述。浏览状态机本体（两端共享）在 `FileBrowserModel.swift`。
extension FileBrowserModel {
    /// 当前连接的主机（外部打开 / 交给 uTable 用）。尚未 connect 时为 nil。
    var connectedHost: ExternalOpenHost? {
        guard let profile = connectedProfile else { return nil }
        return ExternalOpenHost(id: profile.id, name: profile.name,
                                usesJumpHost: profile.jumpHost != nil)
    }

    func remoteDragItem(for entry: RemoteEntry) -> RemoteFileDragItem {
        RemoteFileDragItem(
            scopeID: remoteDragScopeID,
            path: Self.join(currentPath, entry.name),
            name: entry.name,
            isDirectory: entry.isDirectory)
    }

    func remoteDragProvider(for entry: RemoteEntry) -> NSItemProvider {
        let item = remoteDragItem(for: entry)
        let provider = RemoteFileDragPayload.itemProvider(item: item)
        provider.suggestedName = entry.name

        guard !entry.isDirectory else { return provider }
        let size = Self.int64Size(entry.size)
        let type = Self.contentType(forFileName: entry.name)
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { [weak self] completion in
            let progress = Progress(totalUnitCount: max(1, size))
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, CocoaError(.userCancelled))
                    return
                }
                let destinationURL: URL
                do {
                    destinationURL = try Self.promisedDownloadURL(fileName: item.name)
                } catch {
                    completion(nil, false, error)
                    return
                }
                guard await self.downloadWithProgress(
                    remotePath: item.path,
                    fileName: item.name,
                    size: size,
                    to: destinationURL) else {
                    completion(nil, false, NSError(
                        domain: "uTerm.RemoteFileDrag",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "下载失败")]))
                    return
                }
                progress.completedUnitCount = progress.totalUnitCount
                completion(destinationURL, false, nil)
            }
            return progress
        }
        return provider
    }

    @discardableResult
    func moveRemoteDragItem(_ item: RemoteFileDragItem, into target: RemoteEntry) async -> Bool {
        guard target.isDirectory else { return false }
        return await moveRemoteDragItem(item, intoDirectory: Self.join(currentPath, target.name))
    }

    @discardableResult
    func moveRemoteDragItem(_ item: RemoteFileDragItem,
                            intoDirectory targetDirectoryPath: String) async -> Bool {
        guard let provider = sftpProvider, item.scopeID == remoteDragScopeID else { return false }
        let source = RemotePath.normalized(item.path)
        let targetDirectory = RemotePath.normalized(targetDirectoryPath)
        guard Self.canMoveRemoteDragItem(
            sourcePath: source,
            itemName: item.name,
            isDirectory: item.isDirectory,
            targetDirectoryPath: targetDirectory) else { return false }

        let destination = Self.join(targetDirectory, item.name)
        do {
            try await provider.rename(source, to: destination)
            await refresh()
            return true
        } catch {
            report(error, action: String(localized: "移动", comment: "操作名，接在「…失败：原因」前"))
            return false
        }
    }

    private static func canMoveRemoteDragItem(sourcePath: String,
                                              itemName: String,
                                              isDirectory: Bool,
                                              targetDirectoryPath: String) -> Bool {
        guard !itemName.isEmpty, sourcePath != "/" else { return false }
        let destination = join(targetDirectoryPath, itemName)
        guard destination != sourcePath else { return false }
        if isDirectory {
            guard targetDirectoryPath != sourcePath else { return false }
            guard !targetDirectoryPath.hasPrefix(sourcePath + "/") else { return false }
        }
        return true
    }

    private static func contentType(forFileName fileName: String) -> UTType {
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    /// 拖出到 Finder 的文件承诺落盘路径：独立 0700 随机目录 + 清洗过的文件名
    /// （`ExternalFileStager`，与外部打开 / iOS 下载同一套）。
    ///
    /// 不在落盘后收紧到 0600：这份文件会被系统交给拖放目标（桌面 / Finder 窗口），
    /// 用户拿到的就是它，权限应保持 SFTP 下载的默认值。
    private static func promisedDownloadURL(fileName: String) throws -> URL {
        try ExternalFileStager.prepareDestination(
            suggestedName: fileName,
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("uterm-drag-downloads", isDirectory: true))
    }
}

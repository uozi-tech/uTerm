import Foundation
import Citadel
import NIOCore

/// 真实 SFTP 会话：在一个已连上的 `ConnectedClient` 上跑 Citadel SFTP。
actor SFTPSession: SFTPProviding {
    private let connected: ConnectedClient
    private let sftp: SFTPClient

    init(connected: ConnectedClient) async throws {
        self.connected = connected
        self.sftp = try await connected.target.openSFTP()
    }

    func list(path: String) async throws -> [RemoteEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var entries: [RemoteEntry] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                let attributes = component.attributes
                entries.append(
                    RemoteEntry(
                        name: filename,
                        posixPermissions: attributes.permissions,
                        size: attributes.size,
                        modifiedAt: attributes.accessModificationTime?.modificationTime
                    )
                )
            }
        }
        return entries
    }

    func realPath(_ path: String) async throws -> String {
        try await sftp.getRealPath(atPath: path)
    }

    func download(remotePath: String) async throws -> Data {
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            let buffer = try await file.readAll()
            try await file.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await file.close()
            throw error
        }
    }

    func upload(data: Data, toRemotePath: String) async throws {
        let file = try await sftp.openFile(
            filePath: toRemotePath,
            flags: [.write, .create, .truncate]
        )
        do {
            // `ByteBuffer(data:)` 需额外 import NIOFoundationCompat —— 这里直接 writeBytes 即可。
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await file.write(buffer, at: 0)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func write(_ path: String, data: Data) async throws {
        let file = try await sftp.openFile(
            filePath: path,
            flags: [.write, .create, .truncate]
        )
        do {
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await file.write(buffer, at: 0)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func stat(_ path: String) async throws -> RemoteStat {
        let attrs = try await sftp.getAttributes(at: path)
        let size = Int64(attrs.size ?? 0)
        let mtime = attrs.accessModificationTime?.modificationTime ?? Date()
        return RemoteStat(size: size, mtime: mtime)
    }

    func close() async {
        try? await sftp.close()
        await connected.close()
    }
}

import Foundation
@preconcurrency import Citadel
import NIOCore

/// Non-secret metadata about a remote file, surfaced without leaking Citadel types.
public struct SSHRemoteFileInfo: Sendable, Hashable {
    public let size: Int64
    public let modificationDate: Date?

    public init(size: Int64, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }
}

public enum SSHFileTransferError: Error, LocalizedError, Sendable {
    case downloadTooLarge(observed: Int64, maximum: Int64)
    case localFileUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let observed, let maximum):
            return "远程文件过大（\(observed) 字节，超过上限 \(maximum) 字节）"
        case .localFileUnavailable(let path):
            return "无法访问本地文件：\(path)"
        }
    }
}

/// A stand-alone SFTP file-transfer session over one SSH connection.
///
/// USSHKit owns SSH authentication, host-key validation, and the SFTP subsystem;
/// the application supplies endpoint/credential/host-key policy and works purely
/// in terms of `Foundation` values (`URL`, `Data`, paths). Citadel stays internal.
///
/// The session is an `actor`, so all transfers on a given session are serialized;
/// callers do not need to add their own locking around `download`/`upload`.
public actor SSHFileTransferSession {
    private let connected: ConnectedClient
    private let sftp: SFTPClient

    /// Chunk size for streamed transfers. Kept comfortably below swift-nio-ssh's
    /// per-message limit (see `SFTPFile.write`).
    private static let chunkSize = 32 * 1024

    private init(connected: ConnectedClient, sftp: SFTPClient) {
        self.connected = connected
        self.sftp = sftp
    }

    /// Connect to `endpoint` and open an SFTP subsystem channel.
    ///
    /// On any failure after the SSH transport is established the transport is
    /// closed before the error propagates, so a caller that only receives the
    /// thrown error never leaks a live connection.
    public static func open(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy = .ask,
        connectTimeout: Duration = .seconds(30),
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in false }
    ) async throws -> SSHFileTransferSession {
        let connected = try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver
        )
        do {
            let sftp = try await connected.target.openSFTP()
            return SSHFileTransferSession(connected: connected, sftp: sftp)
        } catch {
            await connected.close()
            throw error
        }
    }

    /// `stat(2)` the remote file, returning size and modification date.
    public func stat(_ remotePath: String) async throws -> SSHRemoteFileInfo {
        let attributes = try await sftp.getAttributes(at: remotePath)
        return SSHRemoteFileInfo(
            size: Self.clampedSize(attributes.size),
            modificationDate: attributes.accessModificationTime?.modificationTime
        )
    }

    /// Stream the remote file to `localURL`, overwriting any existing local file.
    ///
    /// - Parameter maximumBytes: When non-nil, the download fails fast (both from
    ///   the pre-flight `stat` and while reading) once the observed size exceeds
    ///   this bound, so a corrupt/hostile server can't exhaust local storage.
    public func download(
        _ remotePath: String,
        to localURL: URL,
        maximumBytes: Int64? = nil
    ) async throws {
        let info = try await stat(remotePath)
        if let maximumBytes, info.size > maximumBytes {
            throw SSHFileTransferError.downloadTooLarge(observed: info.size, maximum: maximumBytes)
        }

        let fm = FileManager.default
        try? fm.removeItem(at: localURL)
        guard fm.createFile(atPath: localURL.path, contents: nil) else {
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            var offset: UInt64 = 0
            var received: Int64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: UInt32(Self.chunkSize))
                let count = buffer.readableBytes
                if count == 0 { break }
                if let maximumBytes, received > maximumBytes - Int64(count) {
                    throw SSHFileTransferError.downloadTooLarge(
                        observed: received + Int64(count),
                        maximum: maximumBytes
                    )
                }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                offset += UInt64(count)
                received += Int64(count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// Upload `localURL` to `remotePath` atomically.
    ///
    /// The bytes are streamed to a sibling temp path first, then moved onto the
    /// target with an SFTP rename, so a mid-transfer failure never leaves the
    /// live file truncated. `SSH_FXP_RENAME` does not overwrite per the SFTP v3
    /// spec, so on a rename collision the target is removed and the rename retried.
    public func uploadAtomically(_ localURL: URL, to remotePath: String) async throws {
        let tempPath = remotePath + ".utable-upload.tmp"
        try await uploadStreaming(localURL, to: tempPath)
        do {
            try await sftp.rename(at: tempPath, to: remotePath)
        } catch {
            try? await sftp.remove(at: remotePath)
            do {
                try await sftp.rename(at: tempPath, to: remotePath)
            } catch {
                try? await sftp.remove(at: tempPath)
                throw error
            }
        }
    }

    private func uploadStreaming(_ localURL: URL, to remotePath: String) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        defer { try? handle.close() }

        let file = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        )
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                var buffer = ByteBuffer()
                buffer.writeBytes(chunk)
                try await file.write(buffer, at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func close() async {
        try? await sftp.close()
        await connected.close()
    }

    /// SFTP sizes are `UInt64`; a corrupt/hostile server can report a value above
    /// `Int64.max`. Saturating avoids a trap that would turn network input into a
    /// process-level crash.
    private static func clampedSize(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
    }
}

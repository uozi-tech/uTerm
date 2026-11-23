import CZstd
import Foundation

/// zstd 解不开：数据坏了、不是 zstd，或者解出来比给的上限还大。
nonisolated enum CodexZstdError: Error, Equatable, Sendable {
    case corrupt
    /// 解出来超过了上限（已经解出 `decoded` 字节时停下的）。
    case tooLarge(decoded: Int)
}

/// 流式解 zstd（vendor 的 libzstd，只有解压部分）。Codex 的压缩记录是一个帧，但这里不假定：多个帧接在一起也照解。
///
/// 一次只喂一块：整份记录下载回来再解要多占一份压缩数据的内存，边读边解只多占一块。
nonisolated final class CodexZstdStream {
    private let stream: OpaquePointer
    /// 最后一次 `decompress` 之后整个帧（或最后一个帧）是不是正好解完了。一个字节都没喂过的不算。
    private(set) var isAtFrameEnd = false
    private(set) var decodedCount = 0

    init() {
        // 只在内存不够时为 nil；那时候整个 App 也快不行了，直接停在这里比带着半个解码器往下走好查。
        stream = ZSTD_createDStream()!
        ZSTD_initDStream(stream)
    }

    deinit { ZSTD_freeDStream(stream) }

    /// 喂一块压缩数据，返回这一块解出来的字节。解出来的总量超过 `limit` 就抛 `tooLarge`。
    func decompress(_ input: Data, limit: Int = .max) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var output = Data()
        let outCapacity = max(Int(ZSTD_DStreamOutSize()), 64 * 1024)
        var buffer = [UInt8](repeating: 0, count: outCapacity)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var inBuffer = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while true {
                let (result, produced) = buffer.withUnsafeMutableBytes { out -> (Int, Int) in
                    var outBuffer = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
                    let code = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    return (code, outBuffer.pos)
                }
                if ZSTD_isError(result) != 0 { throw CodexZstdError.corrupt }
                if produced > 0 {
                    decodedCount += produced
                    if decodedCount > limit { throw CodexZstdError.tooLarge(decoded: decodedCount) }
                    output.append(contentsOf: buffer[0..<produced])
                }
                isAtFrameEnd = result == 0
                // 输入吃完、输出没填满：这一块里能解的都解了（剩下的要等下一块）。
                if inBuffer.pos >= inBuffer.size && produced < outCapacity { break }
            }
        }
        return output
    }

    /// 帧头里写着的原始大小（Codex 压的时候带上了）。没写、或者给的字节不够读出帧头为 nil。
    static func contentSize(ofFramePrefix prefix: Data) -> UInt64? {
        prefix.withUnsafeBytes { raw -> UInt64? in
            guard let base = raw.baseAddress else { return nil }
            let size = ZSTD_getFrameContentSize(base, raw.count)
            // ZSTD_CONTENTSIZE_UNKNOWN = -1，ZSTD_CONTENTSIZE_ERROR = -2（都是 unsigned long long 的最大值附近）。
            guard size != UInt64.max, size != UInt64.max - 1 else { return nil }
            return size
        }
    }

    /// 整段解开（测试与小数据用）。最后没解完一个帧（数据被截断）算坏了。
    static func decompress(_ data: Data, limit: Int = .max) throws -> Data {
        let stream = CodexZstdStream()
        let output = try stream.decompress(data, limit: limit)
        guard stream.isAtFrameEnd else { throw CodexZstdError.corrupt }
        return output
    }

    /// zstd 帧的魔数 `28 B5 2F FD`（小端的 0xFD2FB528）。
    static func looksLikeZstd(_ prefix: Data) -> Bool {
        prefix.prefix(4).elementsEqual([0x28, 0xB5, 0x2F, 0xFD])
    }
}

import Foundation

/// 「这个远端文件能不能在内置编辑器/预览里打开」的唯一判定处。
///
/// 判定只看路径，因为它必须发生在**下载之前**：点开一个 191 MB 的 `.tar.gz`，
/// 用户该立刻看到「这类文件不支持」，而不是先按大小拦一道、更不该先拉一段字节
/// 回来再说不支持。下载之后还有一道内容判据兜底扩展名骗人的文件
/// （`FilePreviewModel.previewableText` 的控制字节嗅探）。
///
/// 采用**黑名单**而不是白名单：终端用户打开的多半是没有扩展名或扩展名千奇百怪的
/// 配置/日志文件（`.p10k.zsh`、`.viminfo`、`nginx.conf`、`authorized_keys`），
/// 白名单会把这些正常文本挡在外面。
nonisolated enum PreviewFileType {
    static let unsupportedMessage = "此类文件不支持预览。可以用本机应用打开，保存后自动上传回主机。"

    /// 可以送进预览/编辑器吗？
    static func isPreviewable(path: String) -> Bool {
        blockedExtension(forPath: path) == nil
    }

    /// 不支持时的说明文案；支持则为 nil。
    static func unsupportedReason(forPath path: String) -> String? {
        guard blockedExtension(forPath: path) != nil else { return nil }
        return unsupportedMessage
    }

    /// 命中黑名单的扩展名（不带点，已小写），供 UI 展示「.gz 文件不支持…」。
    ///
    /// 尾部的纯数字段会先被剥掉，`libncurses.so.5` / `libssl.so.1.1` 才判得出 `so`；
    /// 顺带让 `access.log.1` 仍然是可预览的文本（剥完是 `log`，不在黑名单里）。
    static func blockedExtension(forPath path: String) -> String? {
        var name = (path as NSString).lastPathComponent.lowercased()
        while true {
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, ext.allSatisfy(\.isNumber) else { break }
            let stripped = (name as NSString).deletingPathExtension
            guard stripped != name, !stripped.isEmpty else { break }
            name = stripped
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, blockedExtensions.contains(ext) else { return nil }
        return ext
    }

    /// 明确「不是给人读的文本」的扩展名。新增条目的门槛：内置编辑器打开它一定是
    /// 一屏乱码或一坨二进制，且用户真正想要的是「下载/用外部应用打开」。
    private static let blockedExtensions: Set<String> = [
        // 归档 / 压缩
        "zip", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lz", "lzma", "lz4", "7z", "rar", "tar", "z", "cab", "arj", "cpio",
        "gem", "whl", "egg", "nupkg", "crx", "xpi",
        // 安装包 / 磁盘与虚拟机映像
        "dmg", "pkg", "mpkg", "iso", "img", "deb", "rpm", "apk", "aab", "ipa",
        "msi", "appx", "snap", "flatpak", "vdi", "vmdk", "qcow2", "vhd", "vhdx",
        // 可执行 / 目标文件 / 库
        "exe", "com", "scr", "dll", "bin", "elf", "o", "obj", "a", "lib",
        "so", "dylib", "ko", "class", "jar", "war", "ear",
        "pyc", "pyo", "pyd", "wasm", "node", "rlib", "beam", "nib", "car",
        // 位图/设计稿里内置预览解不了的那些（能解的走 LanguageDetector 的 .image）
        "psd", "ai", "sketch", "fig", "xcf", "raw", "cr2", "nef", "arw", "dng",
        "tga", "exr",
        // 音视频
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ape", "opus",
        "ogg", "oga", "wma", "mid", "midi",
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv",
        "mpg", "mpeg", "m2ts", "3gp", "ogv", "rmvb", "vob",
        // 文档 / 电子书
        "pdf", "doc", "docx", "xls", "xlsx", "xlsb", "ppt", "pptx",
        "odt", "ods", "odp", "pages", "numbers", "key",
        "epub", "mobi", "azw", "azw3", "djvu", "chm",
        // 字体
        "ttf", "otf", "ttc", "woff", "woff2", "eot", "pfb", "pfa",
        // 数据库 / 索引 / 二进制序列化数据
        "db", "db3", "sqlite", "sqlite3", "sqlite-shm", "sqlite-wal",
        "db-shm", "db-wal", "db-journal", "mdb", "accdb", "dbf",
        "myd", "myi", "frm", "ibd", "realm", "ldb", "sst", "idx", "pack",
        "rdb", "bson", "parquet", "orc", "avro", "feather", "arrow", "mat",
        "npy", "npz", "pkl", "pickle", "joblib",
        // 模型权重
        "safetensors", "pt", "pth", "ckpt", "onnx", "tflite",
        "h5", "hdf5", "gguf", "ggml", "caffemodel",
        // 二进制编码的密钥容器 / 证书（.pem/.crt/.pub 是文本，不拦）
        "p12", "pfx", "jks", "keystore", "der", "kdbx",
        // 编辑器 / 调试器的二进制副产物
        "swp", "swo", "swn", "dsym", "pdb", "xcuserstate",
    ]
}

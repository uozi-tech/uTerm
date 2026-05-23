import Foundation

/// 路径 → FileKind 的映射。优先按 basename（如 Dockerfile、nginx.conf），
/// 否则按扩展名；都不命中走 .plainText。
nonisolated enum LanguageDetector {

    static func kind(forPath path: String) -> FileKind {
        let name = (path as NSString).lastPathComponent
        let lowerName = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()

        // basename 优先
        if lowerName == "dockerfile" || lowerName.hasPrefix("dockerfile.") {
            return .code(language: "dockerfile")
        }
        if lowerName == "nginx.conf" {
            return .code(language: "nginx")
        }
        if lowerName == "makefile" {
            return .code(language: "makefile")
        }

        // 图片
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) {
            return .image
        }
        // markdown
        if ["md", "markdown"].contains(ext) {
            return .markdown
        }
        // 代码（带 grammar id）
        if let lang = extensionToGrammar[ext] {
            return .code(language: lang)
        }
        // 纯文本兜底
        return .plainText
    }

    /// 把已识别的 language 字符串转成 grammar id。
    ///
    /// Spec 2A 不带 Tree-sitter 高亮（CodeEditLanguages 被剔出，见 spec §4）；
    /// 此方法始终返回 ""，供后续 spec（Spec 2B+）接管并替换实现，无需改调用方。
    static func grammarId(for language: String) -> String {
        // intentionally always returns "" in Spec 2A
        return ""
    }

    // MARK: 内部映射

    private static let extensionToGrammar: [String: String] = [
        "swift": "swift",
        "go": "go",
        "py": "python", "pyi": "python",
        "rb": "ruby",
        "rs": "rust",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "html": "html", "htm": "html",
        "css": "css",
        "c": "c",
        "h": "c",
        "cc": "cpp", "cpp": "cpp", "hpp": "cpp", "cxx": "cpp",
        "java": "java",
        "kt": "kotlin",
        "conf": "ini", "ini": "ini",
    ]

    /// 与 CodeEditLanguages 实际可用的 grammar id 对齐（供 Spec 2B+ 参考）。
    /// Spec 2A 未使用此集合；保留供后续 grammarId(for:) 实现时复用。
    private static let supportedGrammars: Set<String> = [
        "swift", "go", "python", "javascript", "typescript", "rust",
        "bash", "json", "yaml", "toml", "markdown", "nginx", "dockerfile",
        "html", "css", "c", "cpp", "java", "kotlin", "ruby"
    ]
}

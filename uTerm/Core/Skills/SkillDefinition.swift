import Foundation

/// 一份可安装技能的静态定义。内容以字符串常量内嵌，安装时物化为 `SKILL.md`，
/// 避免新增 Xcode 资源构建阶段。
///
/// **单一真值源**：这些常量与仓库里的 `skills/<slug>/SKILL.md`、`scripts/utermctl`
/// 逐字一致，`uTermTests/SkillDefinitionTests` 会校验两边没有漂移 —— 改文档请改
/// 仓库文件，再把内容同步进来。
nonisolated struct SkillDefinition: Sendable {
    struct SupportFile: Sendable {
        let relativePath: String
        let content: String
        let isExecutable: Bool

        init(relativePath: String, content: String, isExecutable: Bool) {
            self.relativePath = relativePath
            self.content = content
            self.isExecutable = isExecutable
        }
    }

    let slug: String
    let displayName: String
    let markdownContent: String
    let supportFiles: [SupportFile]

    init(
        slug: String,
        displayName: String,
        markdownContent: String,
        supportFiles: [SupportFile] = []
    ) {
        self.slug = slug
        self.displayName = displayName
        self.markdownContent = markdownContent
        self.supportFiles = supportFiles
    }

    /// 命令执行 —— 唯一带客户端脚本的一份，另外三份靠它定位 `utermctl`。
    static let uTermRun = SkillDefinition(
        slug: "uterm-run",
        displayName: "uTerm 远程命令执行",
        markdownContent: Self.uTermRunMarkdown,
        supportFiles: [
            SupportFile(
                relativePath: "bin/utermctl",
                content: Self.controlClientScript,
                isExecutable: true
            )
        ]
    )

    static let uTermFiles = SkillDefinition(
        slug: "uterm-files",
        displayName: "uTerm 远程文件（SFTP）",
        markdownContent: Self.uTermFilesMarkdown
    )

    static let uTermForward = SkillDefinition(
        slug: "uterm-forward",
        displayName: "uTerm 端口转发",
        markdownContent: Self.uTermForwardMarkdown
    )

    static let uTermTerminal = SkillDefinition(
        slug: "uterm-terminal",
        displayName: "uTerm 终端会话",
        markdownContent: Self.uTermTerminalMarkdown
    )

    /// app 内置的全部 uTerm 技能；安装界面按工具整包装这些技能。
    ///
    /// **Wave 0 故意留空**：内容与 `scripts/utermctl` 都还没写，先装等于装一份空技能。
    /// 技能 agent 填完四份 markdown 与客户端脚本后，把它们放进这个数组。
    static let catalog: [SkillDefinition] = []

    // MARK: - 内嵌内容（由技能 agent 填，与仓库文件逐字一致）

    static let uTermRunMarkdown = "# TODO"
    static let uTermFilesMarkdown = "# TODO"
    static let uTermForwardMarkdown = "# TODO"
    static let uTermTerminalMarkdown = "# TODO"

    /// `scripts/utermctl` 的逐字副本（Python 3 标准库，零依赖）。
    static let controlClientScript = "# TODO"
}

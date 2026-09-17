import Foundation

/// 一份可安装技能的静态定义：只有标识与显示名，**不带内容**。
///
/// **真值源是仓库文件**：`skills/<slug>/SKILL.md` 与 `scripts/utermctl`。构建期的
/// 「Copy utermctl CLI and Skills」阶段把它们拷进
/// `uTerm.app/Contents/Resources/Skills/<slug>/`（`uterm-run` 另带 `bin/utermctl`），
/// 随 app 一起签名、公证；安装只是在 `~/.<tool>/skills/<slug>` 建一条**直接指向包内**
/// 的符号链接（见 `SkillInstaller`）。
///
/// 以前这里内嵌全部文档与客户端脚本的字符串常量，安装时物化进沙盒容器。macOS 27 起
/// 别家开发者的进程默认读不到容器里的文件（没给完全磁盘访问权限的 AI CLI 顺着链接
/// 读 `SKILL.md` 直接 `EPERM`），于是改成链到包内，常量随之删掉。
nonisolated struct SkillDefinition: Sendable {
    let slug: String
    let displayName: String

    /// 命令执行 —— 唯一带客户端脚本的一份，另外三份靠它定位 `utermctl`。
    static let uTermRun = SkillDefinition(slug: "uterm-run", displayName: "uTerm 远程命令执行")

    static let uTermFiles = SkillDefinition(slug: "uterm-files", displayName: "uTerm 远程文件（SFTP）")

    static let uTermForward = SkillDefinition(slug: "uterm-forward", displayName: "uTerm 端口转发")

    static let uTermTerminal = SkillDefinition(slug: "uterm-terminal", displayName: "uTerm 终端会话")

    /// app 内置的全部 uTerm 技能；安装界面按工具整包装这些技能。
    ///
    /// 顺序即设置页与文档里的呈现顺序：`uterm-run` 打头（它带客户端，另外三份靠它
    /// 定位 `utermctl`），其余按 文件 / 转发 / 终端 排。必须与仓库 `skills/` 下的目录
    /// 一一对应（`SkillDefinitionTests` 校验）。
    static let catalog: [SkillDefinition] = [
        .uTermRun, .uTermFiles, .uTermForward, .uTermTerminal,
    ]
}

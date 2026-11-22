import Foundation

/// 一份可安装技能的静态定义：只有标识与显示名，**不带内容**。
///
/// **真值源是仓库文件**：`skills/<slug>/`（`SKILL.md` 与 `references/*.md`）与
/// `scripts/utermctl`。构建期的「Copy utermctl CLI and Skills」阶段把它们拷进
/// `uTerm.app/Contents/Resources/Skills/<slug>/`（另带 `bin/utermctl`），随 app 一起签名、
/// 公证；安装只是在 `~/.<tool>/skills/<slug>` 建一条**直接指向包内**的符号链接（见 `SkillInstaller`）。
///
/// 以前这里内嵌全部文档与客户端脚本的字符串常量，安装时物化进沙盒容器。macOS 27 起
/// 别家开发者的进程默认读不到容器里的文件（没给完全磁盘访问权限的 AI CLI 顺着链接
/// 读 `SKILL.md` 直接 `EPERM`），于是改成链到包内，常量随之删掉。
nonisolated struct SkillDefinition: Sendable {
    let slug: String
    let displayName: String

    /// 唯一的一份：`SKILL.md` 讲定位客户端、探活、指定主机、主机密钥、远程执行与错误码，
    /// 文件 / 转发 / 终端会话放 `references/`，按需读。以前拆成四份技能，子技能靠
    /// 「前置见 uterm-run」互相引用，单独触发时模型常漏读前置，故合并。
    static let uTerm = SkillDefinition(slug: "uterm", displayName: String(localized: "uTerm 远程主机"))

    /// app 内置的全部 uTerm 技能；安装界面按工具整包装这些技能。必须与仓库 `skills/`
    /// 下的目录一一对应（`SkillDefinitionTests` 校验）。
    static let catalog: [SkillDefinition] = [.uTerm]

    /// 已并入 `uterm` 的旧技能。uTerm 建过的这些链接在对齐时一并摘掉（新包里已没有它们，
    /// 留着只会悬空），用户自己的同名文件不动。
    static let retiredSlugs: [String] = ["uterm-run", "uterm-files", "uterm-forward", "uterm-terminal"]

    /// 1.12 – 1.16 物化出的 `…/uTerm/Skills/uterm-run/bin/utermctl` 所在的技能名，
    /// `BinLinkInstaller` 认旧链接用。
    static let legacyClientSlug = "uterm-run"
}

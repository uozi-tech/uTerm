// uTerm 补丁（见 UTERM-PATCHES.md 第 3 条）：手写的固定版本信息。
//
// 上游 v1.19.0 起，本文件由 build tool plugin `SwiftTermBuildInfoPlugin`
// （+ 可执行 target `SwiftTermBuildInfoGenerator`）在编译期生成。vendored
// 副本不带这两个 target，原因有二：
//
//   1. plugin 把 `context.package.directoryURL` 传给 generator 去跑 git，而
//      这个目录是 `<uTerm 仓库>/vendor/SwiftTerm`——git 会一路向上找到 uTerm
//      自己的 .git，于是 XTVERSION 会把 **uTerm 的** 分支 / commit / dirty 状态
//      当成 SwiftTerm 的版本报出去。对 vendored 副本来说这是错的。
//   2. vendored 副本本就钉死在一个上游 revision 上，版本信息是常量，没有
//      「编译期才知道」的部分；带上 plugin 只会让 xcodebuild 多一步 host
//      工具构建和 plugin 校验。
//
// 唯一消费者是 `Terminal.cmdXTVERSION`（XTVERSION，`CSI > 0 q` 的应答）。
// 升级 vendored 副本时，把下面两个常量改成新的上游 tag / commit。

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    /// The Git branch, if the build uses a branch checkout.
    public static let branch: String? = nil

    /// The exact Git tag for the current commit, if one is available.
    public static let tag: String? = "v1.19.0"

    /// The full Git commit identifier, if one is available.
    public static let commit: String? = "464df5207fc2432e16c9a23abe538187196daf5f"

    /// Whether the repository had uncommitted changes during the build.
    ///
    /// This value is `nil` when neither Git nor an environment fallback
    /// can determine the worktree state.
    public static let hasUncommittedChanges: Bool? = false

    /// A value suitable for display in logs and diagnostic output.
    ///
    /// This value uses the exact tag when available. Otherwise, it uses the
    /// first 12 characters of the commit identifier. It is `"unknown"` when
    /// the package has no Git information. Modified builds have a `-modified`
    /// suffix.
    public static let version: String = {
        let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}

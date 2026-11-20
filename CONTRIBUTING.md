# 参与贡献 / Contributing

欢迎提 issue 和 pull request。动手前建议先读 [`CLAUDE.md`](CLAUDE.md)：两端共享代码的放法、终端引擎与远控进程的约束都在里面。

## 贡献者许可协议（CLA）

合并之前，PR 里的每一位提交作者都要签署一次 [CLA](CLA.md)。签一次，适用于 uozi 的所有项目。

1. 提 PR 后，CLA 检查会在 PR 下留一条评论，列出还没签的人。
2. 读完 [CLA.md](CLA.md)，在 PR 下**单独发一条评论**，内容只写评论里给出的那句签署语句。
3. 检查会自动重跑；commit status `cla` 变绿即可。之后评论 `recheck` 可手动重跑。

为什么需要 CLA：本项目以 AGPL-3.0 开源，同时由 uozi 在 App Store 等渠道分发，这些渠道的条款与 AGPL 不完全兼容。
CLA 让 uozi 能以 AGPL 之外的条款分发包含你贡献的版本；你保留自己贡献的版权。

注意：提交的作者邮箱要关联到你的 GitHub 账号（Settings → Emails）；`Co-authored-by:` 列出的共同作者也要签；
代表公司贡献、或雇主对你的作品享有权利时，先取得雇主许可，或联系我们签公司版协议。

Every commit author in a pull request must sign our [CLA](CLA.md) once; it covers all uozi projects. After opening a PR,
read the CLA and post a comment containing only the sign-off sentence shown by the CLA check. The `cla` status turns green
automatically; comment `recheck` to re-run it. Make sure your commit email is linked to your GitHub account.

## 提交 PR 之前

- `make test-fast`（macOS）；动了 `uTermMobile/` 或共享代码再跑 `make test-mobile-fast`。动了 `holder/` 或 `relay/` 跑它们自己的 Go 测试。
- 改了界面文案跑 `make sync-strings`（把新文案合进 `uTerm/Localizable.xcstrings`）。
- 改了 `vendor/` 下的第三方源码：按那个目录的 `UTERM-PATCHES.md` 记补丁，不要整目录覆盖。
- 改了 `@Model`：CloudKit schema 要由维护者部署，PR 里写明新增 / 改名的字段（见 `CLAUDE.md`「CloudKit schema」）。
- Go 的测试文件按 `_test.go` 命名；不要删除测试。

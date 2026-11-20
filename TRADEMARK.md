# 名称与图标 / Name and Logo

uTerm 的代码以 [AGPL-3.0](LICENSE) 开源。这个许可证只覆盖代码，**不包括「uTerm」这个名称、应用图标与 logo**：
它们属于柚子星云科技（深圳）有限公司（Uozi Tech），用来让用户分清哪个是官方发布的 uTerm。

## 可以

- 用「uTerm」这个名称指代本项目，比如文章、教程、评测，或者说明你的项目「基于 uTerm」「fork 自 uTerm」。
- 在介绍官方构建时使用它的名称、图标与截图。
- 自己从源码编译、自己使用，不用改名。

## 不可以

- **分发改过的版本时继续叫 uTerm、用 uTerm 的图标**。只要你把改过的构建给别人用（网站下载、应用商店、包管理器、
  公司内部分发都算），就要换一个不会和 uTerm 混淆的名称，换掉应用图标。
- 暗示你的构建是官方版本，或者得到了我们的认可或支持。
- 把「uTerm」用作你自己产品、服务、组织或域名名称的一部分。

改名换图标的地方：工程构建设置里的 `INFOPLIST_KEY_CFBundleDisplayName`，以及 `uTerm/Assets.xcassets` 里的 `AppIcon`。
bundle id 也要换成你自己的（见 README「从源码构建」），否则签不了名。

拿不准的情况，开 issue 问我们。

---

uTerm's source code is licensed under [AGPL-3.0](LICENSE). The license covers the code only, **not the name "uTerm",
the app icon or the logo**. These belong to Uozi Tech (柚子星云科技（深圳）有限公司) and identify official uTerm releases.

**You may** refer to the project as uTerm (articles, tutorials, reviews, "based on uTerm", "a fork of uTerm"), use the
name, icon and screenshots when describing official builds, and build it from source for your own use without renaming.

**You may not** distribute a modified build under the uTerm name or with the uTerm icon. If anyone other than you
uses your build (website downloads, app stores, package managers, internal company distribution), give it a name that
won't be confused with uTerm and replace the app icon. Don't suggest that your build is official or endorsed by us, and
don't use "uTerm" as part of the name of your own product, service, organization or domain.

To rename, change `INFOPLIST_KEY_CFBundleDisplayName` in the project build settings and the `AppIcon` asset in
`uTerm/Assets.xcassets`; also use your own bundle id prefix (see "从源码构建" in the README). If in doubt, open an issue.

# uTerm 对 vendored Citadel 的本地补丁

上游：`https://github.com/orlandos-nl/Citadel`，基线 revision
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`（tag `0.12.1`）。

**Citadel 的源码一行未改**——vendor 它的唯一目的是改它的 `Package.swift`，把
`swift-nio-ssh` 依赖从远程 fork URL 换成我们打过补丁的本地副本
`vendor/swift-nio-ssh`（见其 `UTERM-PATCHES.md`）。

## 为什么 vendor

之前 nio-ssh 的覆盖靠「SwiftPM identity 覆盖」：根工程用
`XCLocalSwiftPackageReference "vendor/swift-nio-ssh"` 声明一个本地 path 包，identity
（= 目录名 `swift-nio-ssh`）与 Citadel 远程依赖 `Wellz26/swift-nio-ssh` 撞名，从而覆盖
那条 transitive 远程依赖。覆盖本身有效，但 SwiftPM 6（Xcode 26）会对这种「同 identity、
不同 location（一个远程 URL、一个本地 path）」报：

```
Conflicting identity for swift-nio-ssh: dependency 'github.com/Wellz26/swift-nio-ssh'
and dependency '.../vendor/swift-nio-ssh' both point to the same package identity
'swift-nio-ssh'. This will be escalated to an error in future versions of SwiftPM.
```

根因：只要 Citadel 的 manifest 还声明远程 `Wellz26/swift-nio-ssh` URL、我们又声明本地同名
包，两者都进依赖图就会撞。唯一彻底消除的办法是不让那条远程 URL 进图——也就是接管
Citadel 的 manifest。于是把 Citadel 也 vendor 进来，仅改它的依赖声明。

## 引用方式

pbxproj 以 `XCLocalSwiftPackageReference "vendor/Citadel"` 引用本目录，替换原先的
`XCRemoteSwiftPackageReference "Citadel"`（`orlandos-nl/Citadel`）。app target 的两个
`Citadel` product 依赖改指向本地包。

`vendor/swift-nio-ssh` **不再**需要根工程的 `XCLocalSwiftPackageReference`——它现在由本包
`Package.swift` 的 `.package(path: "../swift-nio-ssh")` 拉入。app 里 11 处 `import NIOSSH`
仍通过 Citadel 传递可见（与改前一致，app target 从来没有 NIOSSH 的直接 product 依赖）。
依赖图里不再有任何 `swift-nio-ssh` 远程 URL → 撞 identity 的警告消失。

## Package.swift 的改动（相对上游）

1. nio-ssh 依赖：
   ```
   - .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0")
   + .package(path: "../swift-nio-ssh")
   ```
2. 裁剪：删掉 `CitadelServerExample` 可执行 target（连带删掉只它用的 `ColorizeSwift`
   依赖）和 `CitadelTests` 测试 target。只保留 `CCitadelBcrypt`（C target）和 `Citadel`
   library target + `Citadel` library product。其余依赖（swift-nio / swift-log / BigInt /
   swift-crypto）原样保留。

## 更新方式

升级 Citadel 上游：拉新 revision，用其 `Sources/CCitadelBcrypt` 和 `Sources/Citadel`
覆盖本目录对应子目录（保留本文件、`LICENSE` 与裁剪/改过的 `Package.swift`），再核对上游
manifest 有没有新增 Citadel target 依赖需要同步进裁剪版。**不要**直接整目录覆盖。

若哪天 Citadel 上游改用已修的 apple/swift-nio-ssh（不再钉 `Wellz26` fork），则
`vendor/swift-nio-ssh` 和本 vendored Citadel 可一并撤掉，改回普通远程依赖。

> ⚠️ 验证：vendored 包改完后需在 Xcode reset package caches 重解析再编译。隔离构建里
> SourceKit 对 vendored target 的报错多为假阳性，信 xcodebuild。

// swift-tools-version: 6.2

import PackageDescription

/// SSH 栈（USSHKit + USSHCore + NIOSSH + swift-nio + swift-crypto/BoringSSL + swift-asn1 + BigInt + swift-log）
/// 打成**一个**动态 framework，装在 `uTerm.app/Contents/Frameworks/`，由主程序 `uTerm`（有沙盒）和
/// `Helpers/uterm-ssh`（无沙盒，跑在 holder 的 PTY 里）共同链接。之前两边各自静态链一整份，uterm-ssh 那份
/// 和主程序完全重复。
///
/// 规矩（违反了会出现两份 NIO / BoringSSL：重复的类、重复的 Swift 元数据，类型转换与单例都会出错）：
/// - 这两个 target 只声明这一个 product，**不再**直接声明 USSHKit / USSHCore / Crypto / SwiftASN1 这些静态 product；
///   源码照常 `import NIOCore` 等，模块都在这个 product 的依赖闭包里。
/// - iOS（uTermMobile）不用它，照旧静态链。
/// - `uTermRemoteHost` 不能链它（远控进程不能链包内的动态库，见 CLAUDE.md），它本来也不用 SSH 栈。
///
/// 依赖只写 uAppKit：其余的包都由 USSHKit 的依赖闭包带进来，版本由工程的 Package.resolved 钉住。
///
/// 进程内 SSH 测试服务端 `USSHTestServer` 也编进这个 framework：macOS 的测试 bundle 由 App 宿主、
/// 不声明任何包依赖（声明了 Xcode 会改成动态链接、漏掉链接任务），它要的 USSHCore / NIOSSH 只能从这里来；
/// 单独再链一份就是两份 NIOSSH（重复的类型与进程级的算法登记表）。它不随 App 发布：SwiftPM 的依赖不能按
/// Debug / Release 区分，所以 uAppKit 改用编译条件——`USSHTestServer` 的源码整个包在 `#if USSH_TEST_SERVER` 里，
/// 这个条件只在 debug 配置下定义（Xcode 的 Debug 对应 `.debug`），Release 下它是空模块（framework 里没有它的
/// 符号）。代价是 Release 配置编不过测试，测试本来就用 Debug。iOS 的测试不起 SSH 服务端，不链它。
let package = Package(
    name: "USSHStack",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "USSHStack", type: .dynamic, targets: ["USSHStack"]),
    ],
    dependencies: [
        // 与工程里 uAppKit 的版本要求一致（upToNextMinor 2.0.0）：2.0 起 SSH 栈换成 Apple swift-nio-ssh + USSHCore，
        // 去掉了 Citadel product，是不兼容的协议层升级。
        .package(url: "https://github.com/uozi-tech/uAppKit.git", .upToNextMinor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "USSHStack",
            dependencies: [
                .product(name: "USSHKit", package: "uAppKit"),
                .product(name: "USSHTestServer", package: "uAppKit"),
            ]
        ),
    ]
)

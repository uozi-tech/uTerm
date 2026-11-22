// swift-tools-version: 6.2

import PackageDescription

/// SSH 栈（USSHKit + Citadel + swift-nio-ssh + swift-nio + swift-crypto/BoringSSL + swift-asn1 + BigInt + swift-log）
/// 打成**一个**动态 framework，装在 `uTerm.app/Contents/Frameworks/`，由主程序 `uTerm`（有沙盒）和
/// `Helpers/uterm-ssh`（无沙盒，跑在 holder 的 PTY 里）共同链接。之前两边各自静态链一整份，uterm-ssh 那份
/// 和主程序完全重复。
///
/// 规矩（违反了会出现两份 NIO / BoringSSL：重复的类、重复的 Swift 元数据，类型转换与单例都会出错）：
/// - 这两个 target 只声明这一个 product，**不再**直接声明 USSHKit / Citadel / Crypto / SwiftASN1 这些静态 product；
///   源码照常 `import NIOCore` 等，模块都在这个 product 的依赖闭包里。
/// - iOS（uTermMobile）不用它，照旧静态链。
/// - `uTermRemoteHost` 不能链它（远控进程不能链包内的动态库，见 CLAUDE.md），它本来也不用 SSH 栈。
///
/// 依赖只写 uAppKit：其余的包都由 USSHKit 的依赖闭包带进来，版本由工程的 Package.resolved 钉住。
let package = Package(
    name: "USSHStack",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "USSHStack", type: .dynamic, targets: ["USSHStack"]),
    ],
    dependencies: [
        .package(url: "https://github.com/uozi-tech/uAppKit.git", from: "1.24.2"),
    ],
    targets: [
        .target(
            name: "USSHStack",
            dependencies: [
                .product(name: "USSHKit", package: "uAppKit"),
            ]
        ),
    ]
)

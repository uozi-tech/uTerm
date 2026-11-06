// swift-tools-version:5.9
//
// Vendored KCP：纯 C 的 ARQ，MIT。公网直连时控制消息和终端字节走它（视频不走，见 RemoteVideoDatagram）。
//
// 来源：skywind3000/kcp 2.1.1（发布包 SHA-256
// 54d3c80928d206529f67cba6f96f2c98007182b46e3112819b200d914f96e425），只取 ikcp.c、ikcp.h 和 LICENSE，代码未改动。
// 升级步骤见 UTERM-PATCHES.md。

import PackageDescription

let package = Package(
    name: "uTermVendoredKCP",
    products: [
        .library(name: "CKCP", targets: ["CKCP"]),
    ],
    targets: [
        .target(
            name: "CKCP",
            path: ".",
            exclude: ["LICENSE", "UTERM-PATCHES.md"],
            sources: ["src/ikcp.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                // 上游代码，不在这里改，也别让它的警告混进工程的零警告。
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)

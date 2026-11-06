// swift-tools-version:5.9
//
// Vendored libjuice：纯 C 的 ICE 实现（打洞），MPL-2.0。
//
// 来源：paullouisageneau/libjuice v1.7.4（发布包 SHA-256
// 95c088862aa1b88b73d62aa99577135010eb768fcafb252d13aa85a8515ef798），只取 src/、include/ 和 LICENSE，代码未改动。
// 不走上游的 CMake，这里手写 sources，升级步骤见 UTERM-PATCHES.md。

import PackageDescription

let package = Package(
    name: "uTermVendoredJuice",
    products: [
        .library(name: "CJuice", targets: ["CJuice"]),
    ],
    targets: [
        .target(
            name: "CJuice",
            path: ".",
            exclude: ["LICENSE", "UTERM-PATCHES.md"],
            sources: [
                "src/addr.c", "src/agent.c", "src/base64.c", "src/conn.c", "src/conn_mux.c", "src/conn_poll.c",
                "src/conn_thread.c", "src/const_time.c", "src/crc32.c", "src/hash.c", "src/hmac.c", "src/ice.c",
                "src/juice.c", "src/log.c", "src/random.c", "src/server.c", "src/stun.c", "src/tcp.c",
                "src/timestamp.c", "src/turn.c", "src/udp.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/juice"),
                .headerSearchPath("src"),
                .define("JUICE_STATIC"),
                .define("USE_NETTLE", to: "0"),
                // 不需要内置的 TURN 服务端。
                .define("NO_SERVER"),
                // 上游代码，不在这里改，也别让它的警告混进工程的零警告。
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)

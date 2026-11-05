# vendor/libjuice

上游：<https://github.com/paullouisageneau/libjuice>，当前 v1.7.4。

## 本地补丁

没有。`src/`、`include/`、`LICENSE` 与发布包一字不差，只多了本目录的 `Package.swift`（手写 sources、关掉 Nettle 和服务端）和这份说明。

## 升级

1. 从 Release 下载新版本 tar 包，记下 SHA-256，写进 `Package.swift` 头注释。
2. 覆盖 `src/*.c`、`src/*.h`、`include/juice/juice.h`、`LICENSE`。
3. 上游增删 `.c` 文件时，同步 `Package.swift` 的 `sources`（对照上游 `CMakeLists.txt` 的 `LIBJUICE_SOURCES`）。
4. `make test-fast`，再跑 `make test-relay-e2e`。

## 合规

- MPL-2.0：改动这个目录下的文件要以同样许可公开这些文件；链接进 App 不影响其余代码。发版的第三方声明要列上它。
- 密码学：只用 SHA-1 / SHA-256 / HMAC 做 STUN 消息认证（ICE 连通性检查），不加密任何数据，`ITSAppUsesNonExemptEncryption = NO` 的依据不变。业务数据的加密仍由 CryptoKit 负责。

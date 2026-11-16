# vendor/libjuice

上游：<https://github.com/paullouisageneau/libjuice>，当前 v1.7.4。

## 本地补丁

`include/`、`LICENSE` 与发布包一字不差，另有本目录的 `Package.swift`（手写 sources、关掉 Nettle 和服务端）和这份说明。
`src/` 有下面这些改动，每处都带 `uTerm patch #N` 注释，升级时按编号逐条重放：

1. **触发检查立即发**（`src/agent.c`，收到对端 Binding 请求后的「Triggered pair check」）：原来按
   `STUN_PACING_TIME`（50 ms）再加错峰找空槽才发，改成当场发。对端已经在往这边打了，这个检查最可能成功；
   它晚发多久，这一端就晚多久才能往外发数据。公网直连里手机先报连上、发路径确认，Mac 那头要等这个检查成功才
   回得出来（2026-11-16 Duo ↔ mini：「确认 87–134 ms」）。只在收到对端检查时发生，不会形成持续突发。

## 升级

1. 从 Release 下载新版本 tar 包，记下 SHA-256，写进 `Package.swift` 头注释。
2. 覆盖 `src/*.c`、`src/*.h`、`include/juice/juice.h`、`LICENSE`，再按「本地补丁」逐条重放（搜 `uTerm patch`）。
3. 上游增删 `.c` 文件时，同步 `Package.swift` 的 `sources`（对照上游 `CMakeLists.txt` 的 `LIBJUICE_SOURCES`）。
4. `make test-fast`，再跑 `make test-relay-e2e`。

## 合规

- MPL-2.0：改动这个目录下的文件要以同样许可公开这些文件（现在改了 `src/agent.c`，见「本地补丁」）；链接进 App 不影响其余代码。发版的第三方声明要列上它。
- 密码学：只用 SHA-1 / SHA-256 / HMAC 做 STUN 消息认证（ICE 连通性检查），不加密任何数据，`ITSAppUsesNonExemptEncryption = NO` 的依据不变。业务数据的加密仍由 CryptoKit 负责。

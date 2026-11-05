# vendor/kcp

上游：<https://github.com/skywind3000/kcp>，当前 2.1.1。

## 本地补丁

没有。`src/ikcp.c`、`include/ikcp.h`、`LICENSE` 与发布包一字不差，只多了本目录的 `Package.swift` 和这份说明。

## 升级

1. 从 Release 下载新版本 tar 包，记下 SHA-256，写进 `Package.swift` 头注释。
2. 覆盖上面三个文件。
3. `RemoteKCP.swift` 直接读 `IKCPCB` 的字段（`snd_una`、`rx_srtt`、`state`），上游改结构体时要同步。
4. `make test-fast`，再跑 `make test-relay-e2e`。两端 KCP 版本不同可能不兼容，升级算协议变更。

## 合规

- MIT，发版的第三方声明要列上它。
- 不含密码学。

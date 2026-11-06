# uterm-relay 协议，版本 1

中继让手机连上不在同一网络的 Mac。它只做三件事：回答 STUN、转发密封的信令、把两条 TCP 接在一起。
远控握手和所有业务数据在两端之间端到端加密，中继只看得到设备 ID、来源 IP 和流量大小。

同一个端口号（默认 47310）同时开 TCP 和 UDP。

## 密钥

- **成员密钥（P-256）**：服务第一次启动时生成，服务端只留公钥，私钥只写进给设备导入的配置。设备用它证明自己是这台中继的成员。
- **主机密钥（P-256）**：每台 Mac 自己生成。主机 ID 第一次注册时和它绑定，之后必须用同一把签名，防止其他成员顶替这台 Mac。绑定一直保留（不在线也算），最多 1024 个；满了以后新的主机 ID 注册回 `full`，已绑定的照常注册，用 `uterm-relay forget` 腾位置。

签名是 ECDSA over SHA-256，DER 编码，再 base64（标准字母表，带填充）。公钥是 SubjectPublicKeyInfo DER 再 base64。

被签名的消息是 UTF-8 文本，字段用 `\n` 连接：

```text
uterm-relay-v1
<role>
<relayID>
<nonce，base64>
<parameter>
```

`parameter`：`host` 是主机 ID，`client` 为空，`dial` 是主机 ID，`accept` 是 ticket。

## 配置

```json
{
  "format": "uterm-relay",
  "version": 1,
  "name": "home",
  "host": "relay.example.com",
  "port": 47310,
  "relayID": "6F1C…",
  "key": "<成员私钥，32 字节标量，base64>"
}
```

同一份内容也可以写成二维码：`uterm://relay?v=1&n=<名字>&h=<主机>&p=<端口>&i=<relayID>&k=<私钥 base64url>`。

配置里有成员私钥，等同口令。泄露后用 `uterm-relay rotate` 换钥，所有设备重新导入。

## 连接

客户端写 `UTRL` 和一个字节的协议版本（1）。服务端立刻回 hello：

```json
{"relay":"uterm-relay","version":1,"relayID":"…","nonce":"<32 字节随机数，base64>"}
```

版本不同时，服务端在 hello 后面跟 `{"ok":false,"reason":"version"}` 并关闭。

之后每一帧是 `[u32 大端长度][JSON]`，最长 64 KiB。5 秒内没有发出第一帧的连接会被关闭。第一帧的 `role` 决定连接用途。

失败统一回 `{"ok":false,"reason":…}` 并关闭：

| reason | 含义 |
|---|---|
| `version` | 协议版本不同 |
| `auth` | 成员签名不对 |
| `hostKey` | 主机 ID 已绑定别的密钥，或主机签名不对 |
| `full` | 超过容量上限 |
| `offline` | 目标主机不在线 |
| `ticket` | ticket 不存在、已过期，或对端已离开 |
| `invalid` | 格式错误 |

### `host`：Mac 注册

```json
{"role":"host","hostID":"<UUID>","hostKey":"…","sig":"<成员密钥>","hostSig":"<主机密钥>"}
```

回 `{"ok":true}` 后连接保持。同一主机 ID 用同一把密钥再次注册时，旧连接收到 `{"type":"superseded"}` 后被关闭；收到它的一方不要自动重连。

连接上的帧：

| 方向 | 帧 | 含义 |
|---|---|---|
| 中继 → Mac | `{"type":"signal","session":…,"from":<设备 UUID>,"box":…}` | 手机发来的信令 |
| Mac → 中继 | `{"type":"signal","session":…,"box":…}` | 回给该会话的手机 |
| 中继 → Mac | `{"type":"incoming","session":…,"ticket":…}` | 有手机要走中继，Mac 应回拨 `accept` |
| 双向 | `{"type":"ping"}` / `{"type":"pong"}` | 保活 |

Mac 每 60 秒 ping 一次，20 秒没有回应就重连。中继 200 秒听不到 Mac 就把它摘掉。

### `client`：手机控制连接

```json
{"role":"client","sig":"<成员密钥>"}
```

回 `{"ok":true}` 后连接保持：

| 方向 | 帧 | 含义 |
|---|---|---|
| 手机 → 中继 | `{"type":"list"}` | 问哪些主机在线 |
| 中继 → 手机 | `{"type":"hosts","hosts":[<UUID>…]}` | 在线主机 |
| 手机 → 中继 | `{"type":"signal","to":<主机 UUID>,"session":…,"from":<设备 UUID>,"box":…}` | 发信令，`session` 是手机生成的随机串 |
| 中继 → 手机 | `{"type":"signal","session":…,"box":…}` | Mac 的回复 |
| 中继 → 手机 | `{"type":"undeliverable","session":…}` | 目标主机不在线 |
| 双向 | `ping` / `pong` | 保活 |

### `dial`：手机请求中继

```json
{"role":"dial","hostID":"<UUID>","session":"…","sig":"<成员密钥>"}
```

中继生成 ticket（16 字节随机数，base64url），向主机发 `incoming`。Mac 回拨并被接受后，手机收到 `{"ok":true}`，此后每个字节都是对端发来的原始数据。ticket 10 秒过期，手机断开也立即失效。

### `accept`：Mac 回拨

```json
{"role":"accept","ticket":"…","hostSig":"<主机密钥>"}
```

只有 ticket 发给的那台主机能签。回 `{"ok":true}` 后进入转发。

## 信令（中继看不懂）

`box` 是 `base64(nonce ‖ 密文 ‖ tag)`，ChaChaPoly，密钥由两端长期密钥的 X25519 经 HKDF 派生，AAD 绑定方向与 `session`。内容见 `uTerm/Core/Remote/RemoteSignaling.swift`。

## STUN

UDP 端口响应 RFC 8489 Binding Request，回 XOR-MAPPED-ADDRESS，不需要认证。其它报文一律丢弃。

回包永远不比请求大，免得伪造源地址的请求借中继放大流量。XOR-MAPPED-ADDRESS 回包 IPv4 是 32 字节、IPv6 是 44 字节，请求不够长时：够 28 字节就回 `500` 错误（只带 ERROR-CODE），再短就丢弃。libjuice 的请求是 40 字节（SOFTWARE + FINGERPRINT），IPv4 拿得到地址；IPv6 收到 `500`，立刻放弃这台服务器，不会重试二十多秒才收集完。需要 IPv6 映射地址的客户端要把请求补到 44 字节以上。

## 存活和背压

所有 TCP 连接开 keepalive（空闲 10 秒、间隔 5 秒、3 次）；Linux 上 TCP user timeout 25 秒。转发时写完一段才读下一段，慢的一端会拖慢发送端，不会撑爆中继内存。任一端结束，两端一起关闭。

## 限制

默认 64 台在线主机、1024 个主机绑定、每主机 32 个待接 ticket、512 条转发、256 条控制连接、64 条未认证连接；单 IP 每 10 秒 60 条新连接（`RELAY_RATE_PER_IP`）。

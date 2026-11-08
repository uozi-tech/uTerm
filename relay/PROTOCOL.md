# uterm-relay 协议，版本 1

中继让手机连上不在同一网络的 Mac。它只做三件事：回答 STUN、转发密封的信令、把两条 TCP 接在一起。
远控握手和所有业务数据在两端之间端到端加密，中继只看得到设备 ID、来源 IP 和流量大小。

同一个端口号（默认 47310）同时开 TCP 和 UDP。

## 密钥

- **成员密钥（P-256）**：服务第一次启动时生成，服务端只留公钥，私钥只写进给设备导入的配置。设备用它证明自己是这台中继的成员。
- **成员证书**（1.3.0 起；1.2.x 的无有效期证书已不再认）：Mac 给每台配对设备另发一把成员私钥，再用成员密钥签一张证书，写明这把钥匙只能连哪台主机、到什么时候为止。持证书的设备用自己那把签名，只能 `client` / `dial` 那一台主机，不能注册主机、不能再签证书。Mac 忘记这台设备（或邀请没用掉就作废）时吊销它，不必为一台设备换掉所有人的成员密钥。
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

成员证书是成员密钥对下面这段文本的签名（同样是 ECDSA over SHA-256、DER、base64），`member` 是持证书那把钥匙的公钥（SubjectPublicKeyInfo DER 再 base64，原样比较，吊销也认这一串），`scope` 是它能连的主机 ID，`exp` 是到期时间（Unix 秒，十进制）：

```text
uterm-relay-member-v2
<relayID>
<member>
<scope>
<exp>
```

持证书的请求多带四个字段，`sig` 改用自己那把钥匙签：

```json
{"role":"client","member":"<公钥>","cert":"<证书>","scope":"<主机 ID>","exp":1790000000,"sig":"<自己的钥匙>"}
```

证书不对、`scope` 为空、已过期、到期时间比现在晚 180 天以上、已吊销、`role` 是 `host`、`dial` 的主机不是 `scope`，都和签名不对一样直接关闭连接。1.2.x 的证书（`uterm-relay-member-v1`，没有到期时间）不再接受。

有效期由 Mac 定：配对后的证书 90 天，邀请里带的 1 天。剩不到 60 天时，那台设备下一次连上来（局域网或中继都行）Mac 就续一张：同一把钥匙、新的到期时间，设备无感。90 天没连过这台 Mac 的设备证书过期，在同一网络连一次或重新扫码配对即可。1.3.0 之前的中继认不了这种证书，App 按 hello 里的版本决定发证书还是共用的成员密钥。

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

客户端写 `UTRL` 和一个字节的协议版本（1）。服务端回 **32 字节原始随机数**（挑战，不分帧），签名里的 `nonce` 是它的 base64（标准字母表，带填充）。`relayID` 由客户端从配置里取，不经线上传输。

**认证通过之前，中继不说任何别的话**：没有名字、relayID、版本号，也没有失败原因。魔数不对、协议版本不同、签名不对、`role` 不认识、`accept` 的 ticket 不存在或主机签名不对，一律直接关闭连接。扫端口的人只能看到「连上后发对 5 个字节会收到 32 个随机字节」，认不出这是 uTerm 中继，也拿不到版本去挑目标。客户端把「发出请求后对端一言不发就关闭」当成认证失败（配置不对或中继换过钥）。

之后每一帧是 `[u32 大端长度][JSON]`，最长 64 KiB。5 秒内没有发出第一帧的连接会被关闭。第一帧的 `role` 决定连接用途。

`host` / `client` 认证通过时回 `{"ok":true,"server":"<中继版本>"}`，App 据此提醒更新。认证通过之后的失败回 `{"ok":false,"reason":…}` 并关闭：

| reason | 含义 |
|---|---|
| `hostKey` | 主机 ID 已绑定别的密钥，或主机签名不对 |
| `full` | 超过容量上限 |
| `offline` | 目标主机不在线 |
| `ticket` | ticket 已过期，或对端已离开 |
| `invalid` | 格式错误（成员签名之后） |

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
| Mac → 中继 | `{"type":"revoke","member":<公钥>,"exp":<到期>}` | 吊销一张成员证书（1.3.0 起带到期时间） |
| 中继 → Mac | `{"type":"revoked","member":<公钥>}` | 已吊销并存盘 |

吊销立刻断开这把钥匙开着的控制连接和中继转发，之后它认证不过。吊销表存在 `revoked.json`（公钥 → 证书到期时间），证书过期后那条自动清掉（过期的证书本来就进不来）；`exp` 缺省按 180 天记。最多 4096 条（180 天内吊销四千多张才会满），满了丢最快到期的，刚加的那条一定留下；`rotate` 换钥时清空（旧证书随旧成员密钥一起作废）。任何注册着的主机都能吊销：它们手里本来就有能签证书的成员密钥。Mac 发出吊销后等 `revoked` 才划掉，中继不在线时下次注册上补发。

Mac 每 60 秒 ping 一次，20 秒没有回应就重连。中继 200 秒听不到 Mac 就把它摘掉。

### `client`：手机控制连接

```json
{"role":"client","sig":"<成员密钥>"}
```

回 `{"ok":true}` 后连接保持。持证书时只看得见、只发得到它那台主机：`list` 只回那一台（不在线就空），发给别的主机的信令回 `undeliverable`。

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

默认 64 台在线主机、1024 个主机绑定、每主机 32 个待接 ticket、512 条转发、256 条控制连接、64 条未认证连接，其中同一来源最多占 16 条；同一来源每 10 秒 60 条新连接（`RELAY_RATE_PER_IP`，设为 0 时两项来源限制都关闭）。「同一来源」IPv4 按单个地址算，IPv6 按 /64 算：一台 IPv6 主机通常拥有整个 /64，每条连接都能换地址。

注册时容量检查先于绑定：因 `full` 被拒的主机 ID 不会写进绑定表。

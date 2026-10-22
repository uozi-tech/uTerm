# 启停端口转发（`forward …`）

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`SKILL.md`，这里不重复。

**规则只能由用户在 uTerm 界面里创建、修改、删除。** 命令行只能列出来、启动、停止 ——
监听哪个端口、通到哪台机器的哪个端口，是用户的定性，不是你的。需要一条不存在的规则
时，把「要什么」说清楚让用户去建，不要试图用 `run` 起一个 `ssh -L` 来代替。

## 列出来

```sh
"$UTERMCTL" forward list --format table
```

字段：

- `kind`：`local`（-L，本机监听 → 远端目标）、`remote`（-R，远端监听 → 本机目标）、
  `dynamic`（-D，本机 SOCKS5 代理，没有 `destHost`）。
- `status`：`inactive` / `starting` / `active` / `error`。`error` 时看 `issue`。
- `listenHost` / `listenPort`：本地这一头怎么连。`local` 与 `dynamic` 规则起来之后，
  就是往 `127.0.0.1:<listenPort>` 上连。
- `autostart: true` 表示用户已经让它随连接自动拉起，通常不需要你手动 start。
- `bytesIn` / `bytesOut` 是流量快照 —— 判断「隧道到底通没通」比看 `status` 更实。

## 启停

```sh
"$UTERMCTL" forward start -r pg-tunnel      # 规则名或 UUID
"$UTERMCTL" forward stop  -r pg-tunnel
```

两个都归「允许执行命令与写入」开关管（关着时 `mutations_disabled`）。

- 规则名同样按「精确 → 忽略大小写 → 唯一前缀」解析，多条命中是 `rule_ambiguous`，
  `message` 里列着每条的 UUID，改用 UUID。
- `start` **会等到规则起来**（最多一个 SSH 建连超时，默认 30 秒）再回：`ok: true` 就是
  已经 `active`，`rules[0]` 里是它的状态与监听地址，可以直接去连本地端口。只有回
  `forward_failed` 且 `message` 说「秒内未完成启动（仍在连接中）」时，才隔几秒
  `forward list` 再看一眼。
- `start` 是幂等的：已经 `active` 或 `starting` 再 start 都回 `ok`。`stop` 一条本来就
  没在跑的规则也回 `ok`。
- 用完主动 `stop` 掉你自己起的规则，尤其是 `remote`（-R）—— 它在服务器上占着端口。
  `autostart` 的规则不要动，那是用户要一直开着的。

## 端口冲突

`port_in_use` 有两个来源：另一条正在跑的 uTerm 规则占着同一个端口（各种规则都会），
或者本机别的进程占着 `local` / `dynamic` 规则要监听的端口（比如用户手上另有一个
`ssh -L`）。**`remote`（-R）规则在服务器上的端口被占时不是这个码**：服务器拒绝监听，
回的是 `forward_failed`，`message` 里带服务端原话（常见还有 sshd 没开 `GatewayPorts`）。
处理顺序：

1. 先 `forward list` 看这条规则是不是已经 `active` —— 是的话什么都不用做。
2. `local` / `dynamic` 规则占的是**本机**端口，而 `run` 跑的是**远端**命令，查不到
   本机的占用者。让用户自己 `lsof -i :<port>` 看，别拿 `run` 去打别的主机充数。
   `remote` 规则占的是服务器端口，那个可以 `run -H <该主机> -- ss -ltnp` 查。
3. 真要换端口，得用户去界面里改规则。

## 主机密钥

`forward start` 要建新的 SSH 连接时，未知 / 变更的主机密钥同样会拦下它，返回
`host_key_unknown` / `host_key_changed`。处理流程与 `SKILL.md` 的「主机密钥」一节
完全一样：拿 fingerprint 给用户确认，再 `trust`，然后重试。（这台主机已经有转发连接在
用时会复用它，不再重新校验。）

## 硬约束

- 不要创建、修改、删除规则 —— 协议里没有这些动作。
- 不要为了「快一点」改用 `run -- ssh -L …`：那条隧道不受 uTerm 管理，用户在界面里
  看不到、也停不掉，而且会绕开他对这台主机做的定性。
- 隧道通了之后连上的数据库 / 服务里可能是生产数据。要动它们之前先问用户。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `rule_not_found` | 没有这个名字/UUID 的规则 |
| `rule_ambiguous` | 名字匹配到多条，改用 `message` 里列出的 UUID |
| `port_in_use` | 监听端口被另一条规则或本机别的进程占了（退出码 `1`） |
| `forward_failed` | 隧道没建起来（消息里是原话：远端拒绝 -R、目标不可达、认证失败、启动超时） |

其余错误码见 `SKILL.md`。

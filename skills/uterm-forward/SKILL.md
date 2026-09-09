---
name: uterm-forward
description: 通过 uTerm 启停用户已保存的 SSH 端口转发规则（本地 -L / 远程 -R / 动态 SOCKS），并查看它们的运行状态与流量。当需要打通到远程数据库、内网服务的隧道，或排查隧道没起来的原因时使用。
---

# 用 uTerm 启停端口转发

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`uterm-run`，这里不重复。

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
  改用 `id`。
- `start` 是幂等的：已经 `active` 再 start 不会出问题。
- **start 之后不要立刻宣布成功**：回一次 `forward list` 看 `status` 变成 `active`，
  再去连本地端口。
- 用完主动 `stop` 掉你自己起的规则，尤其是 `remote`（-R）—— 它在服务器上占着端口。
  `autostart` 的规则不要动，那是用户要一直开着的。

## 端口冲突

`port_in_use` 表示本机（`local` / `dynamic`）或远端（`remote`）那个监听端口已经被占了。
常见原因是同一条规则已经在跑，或者用户手上另有一个 `ssh -L`。处理顺序：

1. 先 `forward list` 看这条规则是不是已经 `active` —— 是的话什么都不用做。
2. `local` / `dynamic` 规则占的是**本机**端口，而 `uterm-run` 的 `run` 跑的是**远端**
   命令，查不到本机的占用者。让用户自己 `lsof -i :<port>` 看，别拿 `run` 去打别的
   主机充数。`remote` 规则占的是服务器端口，那个可以 `run -H <该主机> -- ss -ltnp` 查。
3. 真要换端口，得用户去界面里改规则。

## 主机密钥

`forward start` 会真的建 SSH 连接，所以未知 / 变更的主机密钥同样会拦下它，返回
`host_key_unknown` / `host_key_changed`。处理流程与 `uterm-run` 的「主机密钥」一节
完全一样：拿 fingerprint 给用户确认，再 `trust`，然后重试。

## 硬约束

- 不要创建、修改、删除规则 —— 协议里没有这些动作。
- 不要为了「快一点」改用 `run -- ssh -L …`：那条隧道不受 uTerm 管理，用户在界面里
  看不到、也停不掉，而且会绕开他对这台主机做的定性。
- 隧道通了之后连上的数据库 / 服务里可能是生产数据。要动它们之前先问用户。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `rule_not_found` | 没有这个名字/UUID 的规则 |
| `rule_ambiguous` | 名字匹配到多条，改用响应里的 `id` |
| `port_in_use` | 监听端口被占 |
| `forward_failed` | 隧道建立失败（消息里是原话，常见是远端拒绝 -R 或目标不可达） |

其余错误码见 `uterm-run`。

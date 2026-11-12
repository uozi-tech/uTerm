# 端口转发（`forward …`）

客户端怎么定位、探活怎么做、主机怎么指定、主机密钥怎么处理、错误码总表都在
`SKILL.md`，这里不重复。

命令行能**列出来、新建、启动、停止、删除**规则，**不能修改**（换端口、换目标、开自启
都回界面）。需要一条不存在的规则时自己建，别用 `run` 起一个 `ssh -L` / `ssh -R` 来代替。
用户已有的规则是他的定性：可以启停，**不要删**；你只删你自己建的。

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

## 新建

```sh
"$UTERMCTL" forward add -H ubuntu-k3s -n k3s-to-mac-18443 \
    --kind remote --listen 192.168.31.122:18443 --dest 127.0.0.1:18443
"$UTERMCTL" forward add -H prod-db -n pg --kind local --listen 15432 --dest 10.0.0.9:5432
"$UTERMCTL" forward add -H bastion -n socks --kind dynamic --listen 1080
```

- `--kind`：`local`（-L）、`remote`（-R）、`dynamic`（-D，SOCKS5，不给 `--dest`）。
- `--listen [HOST:]PORT`：`local` / `dynamic` 开在**本机**，`remote` 开在**服务器**上。
  HOST 缺省 `127.0.0.1`；`remote` 要让服务器以外的机器（同网段的 VM、pod）连进来，就写
  服务器的网卡地址或 `0.0.0.0`，而且服务器的 sshd 要开 `GatewayPorts clientspecified`
  （或 `yes`），否则 sshd 只肯绑回环。IPv6 写成 `[::1]:8080`。
- `--dest HOST:PORT`：`local` 是**服务器**能到的地址，`remote` 是**本机**能到的地址。
- 规则名在同一台主机上不能重名（`rule_exists`）。监听端口撞上同一侧的另一条规则时回
  `port_in_use`（本机这一侧跨主机也算，服务器那一侧只和同一台主机的规则比）。
- 新建**只保存、不启动**，也不会开自启。建完紧接着 `forward start -r <名字> -H <主机>`。
  起名带上用途，方便用户在界面里认出来，也方便你之后找回来删掉。
- 归「允许执行命令与写入」开关管。新规则会立刻出现在 uTerm 的端口转发界面里，并随 iCloud
  同步到用户的其他设备。

## 删除

```sh
"$UTERMCTL" forward remove -r k3s-to-mac-18443 -H ubuntu-k3s
```

在跑就先停再删。开着自启（随连接 / 随 App 启动）的规则拒绝删，回 `rule_protected`
（退出码 `3`）—— 那是用户要一直开着的，让他在界面里处理。任务做完、用户不再需要时，删掉
你建的规则；用户说要留着就别删。

## 启停

```sh
"$UTERMCTL" forward start -r pg-tunnel      # 规则名或 UUID
"$UTERMCTL" forward stop  -r pg-tunnel
```

两个都归「允许执行命令与写入」开关管（关着时 `mutations_disabled`）。

- 规则名同样按「精确 → 忽略大小写 → 唯一前缀」解析，多条命中是 `rule_ambiguous`，
  `message` 里列着每条的 UUID，改用 UUID，或加 `-H <主机>` 只在那台主机的规则里找。
  `start` / `stop` / `remove` / `list` 都接受 `-H`。
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
3. 真要换端口：你自己建的规则，`remove` 掉再用新端口 `add`；用户的规则让他去界面里改。

## 主机密钥

`forward start` 要建新的 SSH 连接时，未知 / 变更的主机密钥同样会拦下它，返回
`host_key_unknown` / `host_key_changed`。处理流程与 `SKILL.md` 的「主机密钥」一节
完全一样：拿 fingerprint 给用户确认，再 `trust`，然后重试。（这台主机已经有转发连接在
用时会复用它，不再重新校验。）

## 硬约束

- 不要修改规则、不要删用户已有的规则 —— 只删你自己建的。
- 不要为了「快一点」改用 `run -- ssh -L …`：那条隧道不受 uTerm 管理，用户在界面里
  看不到、也停不掉，而且会绕开他对这台主机做的定性。
- 隧道通了之后连上的数据库 / 服务里可能是生产数据。要动它们之前先问用户。

## 错误码（本面新增的）

| code | 含义 |
|---|---|
| `rule_not_found` | 没有这个名字/UUID 的规则 |
| `rule_ambiguous` | 名字匹配到多条，改用 `message` 里列出的 UUID |
| `rule_exists` | `add`：这台主机上已有同名规则 —— 换个名字，或先确认那条是不是就是你要的（退出码 `1`） |
| `rule_protected` | `remove`：规则开着自启，只能用户在界面里删（退出码 `3`） |
| `port_in_use` | 监听端口被另一条规则或本机别的进程占了（退出码 `1`） |
| `forward_failed` | 隧道没建起来（消息里是原话：远端拒绝 -R、目标不可达、认证失败、启动超时） |

其余错误码见 `SKILL.md`。

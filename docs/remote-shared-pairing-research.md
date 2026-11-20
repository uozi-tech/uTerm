# 配对过的 Mac 能不能在同一 Apple ID 的设备间共用（调研与 P0，2026-11-16）

> **已被取代（2026-11-16）**：主控端的一对一确认（§8–§12，`RemoteSibling*`）已删掉，换成设备组，见 `docs/remote-device-group-design.md`。被控端的部分（§9：消息 50–53、`RemoteVouch`、`peerVouches`）照旧有效，只有一条规则变了（G3，设备组方案 §8 / §15）：同组设备请求的撤销（消息 52）只删信任与来路、**不再拉黑**，同时连带撤掉一层层由它担保的设备（发请求的那台除外），之后同组设备可以重新替它开通；Mac 主人在 Mac 上撤销的照旧拉黑。下文里「撤销后永远不能借担保回来」的说法只对 Mac 主人的撤销成立。下文的类型名、文件名是当时的。

问题：同一 Apple ID 下的 iPhone / iPad / Mac，只要有一台和某台 Mac 配对过，其它设备能不能直接用，不再配对。

## 结论

1. **每台设备都要单独配对，原因有三个，主要卡在被控端。**
   - 每台设备各有一把长期私钥（X25519）和一个设备 ID，存在本机、不同步。
   - 信任表也只存本机。主控端记的「我控制的主机」、被控端记的「允许控制我的设备」都在 `ThisDeviceOnly` 钥匙串里。
   - 被控端只认 **(设备 ID, 长期公钥)** 这一对，而且公网信令要先按设备 ID 查到对方公钥才解得开。所以只同步主控端的记录没用：新设备连局域网会弹审批，走公网连一句回应都收不到。
2. **三种方案都不推荐照原样做。**
   - (a) 共用一把同步的私钥：Mac 的长期私钥同时是它作被控端的身份，不能同步。共用设备 ID 还会让被控端把几台设备当成一台。丢一台设备只能全体换钥匙、重新配对。
   - (b) 离线证书：要新加「账号根钥匙」、证书链、信令外层和吊销表，改动最大。根钥匙放 iCloud 钥匙串的话，安全性和 (a) 差不多。
   - (c) 同步配对记录：只同步公钥和中继时主机仍不认新设备。要做到免确认，就得同步一个能反复用的配对凭据，这个凭据就是口令。
3. **推荐 (b) 的在线变体，暂叫「已配对设备担保」。** 新设备把自己的公开身份写进 iCloud 钥匙串，作为一个请求。你在一台已配对的旧设备上确认，两台设备上的 6 位码要对得上。之后旧设备经**它和那台 Mac 已有的加密连接**请 Mac 记下新设备：Mac 写进信任表，并按新设备自己的公钥签中继证书。新设备随后照常连接，Mac 认识它。
   - 每台设备仍有独立的钥匙，可以单独吊销，也不用为它引入新的长期秘密。
   - 主机始终是唯一的授权方。别人的 Mac 默认看得到「由谁添加」，可以一并撤掉。
   - 被控端要加两条消息和一个能力字符串。老版本主机不认就退回手动配对，老主控端不受影响。
   - 这不会让已配对设备多出任何权力：它本来就能远程打开那台 Mac 的设置出一张邀请，再用新设备去扫（见 §4.1）。

四条默认值已由 user 按推荐定下（§6）。P0 的落地见 §8，P1 见 §9，P2 见 §10，P3 见 §11。

---

## 1. 现状：身份、信任表、中继存在哪

### 1.1 存储一览

| 东西 | 存在哪 | 同步？ | 代码 |
|---|---|---|---|
| 长期私钥 X25519（账号 `identity`）。**Mac 上主控、被控两个方向共用一把** | 钥匙串 `com.uozi.uTerm.remote`，`AfterFirstUnlockThisDeviceOnly` | 否 | `RemoteIdentityStore.localIdentity()`、`RemoteKeychainStorage`（[RemoteIdentityStore.swift:203](../uTerm/Core/Remote/RemoteIdentityStore.swift:203)、`:239`） |
| 设备 ID（UUID），两个方向也共用 | UserDefaults `remote.deviceID` | 否 | `RemoteLocalDevice.id()`（`RemoteIdentityStore.swift:266`） |
| 中继上的主机身份 P-256（账号 `relayHostKey`），只有被控端用 | 同上 | 否 | `RemoteIdentityStore.relayHostKey()` |
| 被控端信任表 `.controllers`：允许来控制本机的设备（`trustedPeers` / `blockedPeers`） | 同上 | 否 | `RemoteTrustRole`（`:49`） |
| 主控端信任表 `.hosts`：本机控制的主机（macOS 上是 `trustedHosts` / `blockedHosts`，iOS 沿用 `trustedPeers`） | 同上 | 否 | 同上 |
| 主控端记的某台主机的中继（别人的中继、或成员证书） | `.hosts` 表里 `RemotePeer.relay` | 否 | `RemoteIdentityStore.swift:22` |
| 被控端发给某台设备的中继成员证书（吊销用） | `.controllers` 表里 `RemotePeer.relayGrant` | 否 | `:24` |
| 本机默认中继（中继本身的成员密钥） | 钥匙串 `com.uozi.uTerm.remote.relay`，**可同步** | 是 | `RemoteRelayConfigStore`（[RemoteRelayConfig.swift:241](../uTerm/Core/Remote/RemoteRelayConfig.swift:241)） |
| 被控端「允许经公网接入」的设备 | UserDefaults `remote.internetDevices` | 否 | `DefaultsKey.swift:83`、`uTermApp.swift:121` |
| 共享给某台 Mac 的文件夹（反方向文件） | UserDefaults `remote.sharedFolders` | 否（存的是本机路径） | `RemoteFileSharingStore` |
| 手机存的某台 Mac 的登录密码（远程解锁） | 钥匙串 `com.uozi.uTerm.remote.unlock`，绑生物识别、仅本机 | 否（user 定：密码只存手机） | `KeychainRemoteUnlockStore`（`uTermMobile/Screens/Remote/RemoteUnlockVault.swift:39`） |

被控端跑在远控进程 `uTermRemoteHost` 里，没有钥匙串访问组。App 在 `hello` 里把 `RemoteHostAgentBridge.secretAccounts` 这四个账号（`identity`、`relayHostKey`、`trustedPeers`、`blockedPeers`）原样交过去（[RemoteHostAgentBridge.swift:318](../uTerm/Features/Remote/RemoteHostAgentBridge.swift:318)）。远控进程改了信任表，就用 `persistSecret(account:data:)` 写回 App（`RemoteHostAgentProtocol.swift:254`），开通公网接入用 `grantInternetAccess`（`:258`）。

### 1.2 握手怎么认身份

- 密钥派生相当于 Noise KK：`ee ‖ es ‖ se`，把双方的长期公钥都绑进去（[RemoteCrypto.swift:15](../uTerm/Core/Remote/RemoteCrypto.swift:15)）。第一帧密文能解开，就证明对方持有对应的长期私钥；另有 `key-confirm` 兜底。
- 第一次见面防中间人靠 6 位核对码，码从握手记录派生，不参与密钥推导。
- `RemoteHello` 带 `deviceID`、`staticKey`、可选的 `pairingProof` 和 `platform`（[RemoteProtocol.swift:557](../uTerm/Core/Remote/RemoteProtocol.swift:557)）。

### 1.3 被控端按什么认人

`RemoteHostConnection.handshake()`（[RemoteHostConnection.swift:145](../uTerm/Features/Remote/RemoteHostConnection.swift:145)）：

- **局域网**，按顺序判：
  1. `identity.recognizes(id:publicKey:)` 为真，说明设备 ID 和公钥都与信任表一致（`RemoteIdentityStore.swift:178`），直接放行。
  2. 带着本机正在出示的邀请凭据，核销后放行（`redeemPairingProof`，`RemoteHostServer.swift:554`）。
  3. 其余情况弹审批框，人在 Mac 上点「允许」。同一设备 ID 换了公钥（重装过）也走这一步。
- **公网**（`authorizeFromInternet`，`:216`）：
  - 必须认得这台设备，**且**勾选了公网接入；或者带着邀请凭据。
  - **不弹审批框**，防止拿到中继配置的人远程刷弹窗骗点击。
  - 更早的一道门在信令：`RemoteSignalResponder.recognize` 按设备 ID 查公钥，查不到的设备收不到任何回应（[RemoteSignaling.swift:192](../uTerm/Core/Remote/RemoteSignaling.swift:192)、`:206`）。凭邀请来的设备走 `p1:` 外层，外层的密钥由邀请令牌派生（`:141`）。

注释里写明「同一 Apple ID 不再算数」（`RemoteIdentityStore.swift:178` 上方）。

### 1.4 主控端存什么、怎么核对

- 主控端存的是 `.hosts` 表里每台主机的 `RemotePeer`：设备 ID、名字、长期公钥、别名、platform，以及可选的 `relay`。
- 连上后核对设备 ID 和公钥，对不上就报 `peerIdentityChanged`（[RemoteMacClient.swift:497](../uTerm/Core/Remote/RemoteMacClient.swift:497)、`:503`）。
- 主机回 `.trusted` / `.approved` 时，主控端把主机记进表里（`handlePairing`，`:589`）。
- 「忘记」只删本机这一条（`:634`）。

### 1.5 邀请怎么带中继、怎么跨 Apple ID

- `RemotePairingInvitation`（[RemotePairing.swift:18](../uTerm/Core/Remote/RemotePairing.swift:18)）的格式是 `uterm://pair?v=1&d=&n=&k=&t=`：主机 ID、名字、主机公钥，加 16 字节一次性令牌，有时限。被控端开着公网接入时，再带 `rn/rh/rp/ri/rk`（中继），中继 1.3.0 起还带 `rs/rc/re`（只能连这台主机的成员证书，有效期 1 天，配上后续成 1 年）。
- 主控端在握手里带 `pairingProof = HMAC(令牌, 用途 ‖ 主控端公钥 ‖ 主机公钥)`（`:105`），所以凭据换到别的设备上用不了。走公网时，信令外层 `p1:` 用令牌派生的密钥封住主控端公钥，中继看不到。
- 邀请里没有任何和 Apple ID 相关的东西，跨 Apple ID 是因为它本来就不看账号。
- 中继成员证书的私钥由**主机生成**再发给设备（`RemoteRelayConfig.certificate(for:)`，[RemoteRelayConfig.swift:94](../uTerm/Core/Remote/RemoteRelayConfig.swift:94)）。成员证书从不存成默认中继，因为默认中继会同步到本人的 Mac（`RemoteRelayPlacement`，`:211`）。

### 1.6 历史：iCloud 名册已经删过一次

2026-11-07 之前的测试版有 `RemoteCloudRoster`：同一 Apple ID 的设备把公开身份（设备 ID、名字、公钥）写进 iCloud 钥匙串 `com.uozi.uTerm.remote.roster`，被控端看到对得上的条目就**直接信任**。69fea537 按 user 的决定删掉了它（`docs/remote-control-research.md` §16「所有设备都要配对，不论是不是同一 Apple ID」）。现在启动时还会撤下本机在旧名册里那一条（`RemoteLegacyRoster`，`RemotePairing.swift:124`），免得还没升级的设备继续凭它放行。

所以这次要回答的不是「同一 Apple ID 要不要自动信任」，那条已经否了。要回答的是：**怎样让你在一台设备上的配对，在你明确同意之后，带到你的其它设备上去**。另外：
- 新的名册**不能复用** `com.uozi.uTerm.remote.roster` 这个 service，否则还在跑旧测试版的设备会凭它自动放行。
- 被控端**永远不读**新名册。

## 2. 问题 1：为什么每台都要单独配对

三个原因都有：

1. **每台设备各有一把私钥**，`ThisDeviceOnly`，注释里明说不跟 iCloud 走，理由是「另一台设备拿到这把私钥就能冒充本机」。
2. **两张信任表都只在本机。** 主控端的 `.hosts` 不同步，新设备连「有哪些 Mac、公钥是多少」都不知道。
3. **被控端只认 (设备 ID, 公钥)。** 新设备的 ID 和公钥它没见过：局域网弹审批，公网连信令都不回。这一条才是根本：就算把主控端的记录同步过去，主机这边不认新设备，还是用不了。

还有一个隐含约束：**Mac 的长期私钥和设备 ID 同时是它作被控端的身份。** 把 Mac 的主控身份同步出去，就等于把它的被控身份也同步出去：Bonjour、中继注册、核对码全都会撞。

## 3. 约束

- **被控 Mac 可能是别人的**（跨 Apple ID 邀请）。别人的 Mac 上记的是「我的 iPhone 可以控制它」。我加 iPad 时，对方应当看得到、撤得掉，最好还能关掉这个功能。
- **user 定：同一 Apple ID 本身不构成信任**（§1.6）。
- **公网不弹审批框**（§1.3）。
- **XPC 协议只加不改；远控进程没有钥匙串**，身份和信任表由 App 交过去（`secretAccounts`）。升级窗口里，旧远控进程可能还在用旧格式重写信任表（`persistSecret` 原样写回整份 JSON），给 `RemotePeer` 加的新字段会被它丢掉。
- **Secure Enclave**：CryptoKit 的 SE 只支持 P-256，现在的 X25519 长期私钥本来就不在 SE 里。SE 里的钥匙不能导出，也不能同步。所以「私钥放 iCloud 钥匙串」不是让私钥离开 SE，而是**把将来放进 SE 的路永远堵死**。
- **iCloud 钥匙串能拿到什么**：凡是加入了这个 Apple ID 钥匙串圈的设备都能拿到同步条目。加入要 Apple ID 密码，加上一台旧设备的密码或批准。钥匙串圈里已经有同步的 SSH 私钥、API Key 和默认中继的成员密钥，所以「攻击者在钥匙串圈里」时，本来就已经能拿下你的 SSH 主机。远程控制的风险要放在这个背景下比较：方案不该让这种攻击者**不经你点头就**多拿到远程控制。

## 4. 问题 2：方案对比

### (a) 同一 Apple ID 的设备共用一把主控身份（私钥进 iCloud 钥匙串）

做法：主控方向用一把 `kSecAttrSynchronizable` 的 X25519 私钥。主机按 (设备 ID, 公钥) 认人，所以设备 ID 也必须共用，否则老主机不认。

- **安全**
  - 丢一台设备就等于共享私钥泄露。唯一的补救是换钥匙，换了以后**所有设备、对每台主机**都要重新配对。
  - 不能单独吊销某一台：主机眼里只有一台设备。
  - 钥匙串圈里的任何设备都能冒充，包括家里共用的 Mac，以及登录着你 Apple ID 的那台被控 Mac 自己。
  - 将来进不了 SE。
- **功能冲突**（被控端按设备 ID 合并连接）
  - `connectedControllers()` 同一 ID 只取最新一条（[RemoteHostServer.swift:425](../uTerm/Features/Remote/RemoteHostServer.swift:425)）。
  - `fileConnection(toDevice:)` 取最新一条（`:455`）：反方向文件可能发到不提供文件的 iPhone。
  - 被控 Mac 终端里 `utermctl` 的默认主控设备、接管归属都按设备 ID 算。
  - `rememberRecognized` 跟着每次连接改名字，被控端列表里设备名会来回跳。
  - 公网接入勾选、`relayGrant` 只有一份，中继证书的私钥也要跟着同步。
- **Mac 的问题**：Mac 的私钥和设备 ID 两个方向共用（§2）。要做 (a)，得先把 Mac 的主控身份拆成单独一把钥匙、单独一个 ID。拆完以后，所有 Mac 主控端对每台主机都要**重新配对一次**，「老主机不用改」这个唯一的好处在 Mac 上也没了。
- **协议与兼容**：iOS 设备拿第一台 iPhone 现有的钥匙当共享钥匙的话，老主机不用改就认。Mac 主控端不行（见上）。
- **改动量**：iOS 小（换一个存储后端，加迁移）；Mac 中（拆身份、迁移、全体重配）。还要在被控端改那几处按设备 ID 合并的逻辑，否则功能出错，而那就是协议层面的改动了。
- **别人的 Mac**：对方只看到「一台设备」，不知道我又加了 iPad，也没法单独踢掉它。

**不推荐。** 安全上最差，而它唯一的优点「老主机不用改」只在 iOS 上成立，换来的是被控端一堆按设备 ID 合并的逻辑出错。

### (b) 每台设备身份独立，被控端信任「账号」，由账号签发设备证书（离线委托）

做法：每个账号一把签名根钥匙（P-256 或 Ed25519）。配对时主机除了记设备，还记「账号公钥」。新设备拿着根签的设备证书 `{设备 ID, X25519 公钥, 到期时间}`，握手 `RemoteHello` 新加 `accountCert` 字段。主机不认识这个设备 ID，信令也要加一层外壳（`p2:`）把证书带进去，类似邀请的 `p1:`。

- **根钥匙放哪**是关键：
  - 放 iCloud 钥匙串：钥匙串圈里谁都能签，安全性退回到接近 (a)。好一点的是每台设备钥匙独立、可以单独吊销。
  - 只放第一台设备（P-256 可以进 SE）：那台设备丢了就加不了新设备，要再设计「根轮换」，被控端还要认新根。
- **吊销**：被控端离线验证证书，吊销表只能靠设备连上时推过去。不在线的主机会一直认被吊销的证书，只能靠短期证书加续期来缓解，又多一套续期逻辑（中继证书那套已经够复杂了）。
- **优点**：新设备能在担保设备不在线时直接用；主机不用事先知道新设备。
- **协议与兼容**：要加 hello 字段、信令外层，信任表加一类「账号」条目，远控进程的信任表格式也要变（`secretAccounts` 加账号，且要防旧进程覆盖）。老主机不认，退回手动配对。
- **改动量**：大。证书格式、根钥匙管理、信令外层、吊销与续期、两端界面都要做。
- **别人的 Mac**：要显示「信任的是某个账号」，并让对方能选「只信这台设备」还是「信这个账号」。

### (c) 把配对记录（对端公钥、中继配置）同步，新设备拿到后自动发起一次免确认配对

两种做法，取舍差别很大：

- **c1 只同步主控端的记录**（主机 ID、名字、公钥、中继），被控端不改。新设备能列出那些 Mac，也知道该核对哪把公钥，但主机仍然不认它：局域网要有人在 Mac 前点「允许」，公网信令不回。**做不到「免确认」。** 价值仅限于新设备有一份主机目录，局域网审批时能提前核对主机身份。
- **c2 再同步一个可以反复用的「再配对凭据」**：配对时主机多发一个长期令牌，新设备凭它走现有的 `pairingProof` 核销路径，主机自动信任。
  - 安全：这个令牌就是口令。钥匙串圈里谁都能用它，主机分不清是你的 iPad 还是攻击者。和 (a) 一样是共享秘密，好在事后可以按设备吊销，令牌也能由主机轮换。
  - 中继证书不能同步（每台设备一张），新设备要连上后由主机重发。
  - 协议：被控端要支持可多次使用的令牌；`p1:` 信令外层现在只认「此刻正在出示的邀请」，要改成也认长期令牌。改动中等。老主机不认长期令牌，退回手动配对。
- **改动量**：c1 小，c2 中等。

**c2 不推荐**：「同步的口令就等于信任」，本质上就是删掉的那份名册换了个形式，只是多了吊销。c1 可以作为推荐方案的一部分（新设备的主机目录）。

### (d) 推荐：已配对设备在线担保（(b) 的在线变体）

**流程**

1. **新设备登记。** 新设备打开远程控制时，把自己的公开身份写进 iCloud 钥匙串的**新** service `com.uozi.uTerm.remote.devices`，account 是设备 ID。内容是 `{设备 ID, 名字, 机型, platform, X25519 公钥, 中继成员公钥 P-256, 登记时间}`，私钥仍是 `ThisDeviceOnly`。这份名册**只是请求队列，被控端从不读它**。iCloud 钥匙串关着时，这个功能不可用，提示去手动配对。
2. **旧设备确认。** 已配对的旧设备看到新条目，提示「你的 iPad『…』想使用你配对过的 N 台 Mac」。两台设备都显示 6 位码，照蓝牙「数字比较」配对的顺序算：新设备先对自己的随机数做承诺，旧设备看到承诺后才出自己的随机数，新设备再揭示，码由两个随机数一起算出。名册里的冒充者在看到对方随机数之前就得定下自己那一半，碰上同一个码只有百万分之一。（只让旧设备出随机数、新设备显示 `H(公钥 ‖ 随机数)` 不够：冒充者能往名册里给真新设备写一条假的随机数，碾出和旧设备上相同的码。）两台设备都在你手里，对得上就点「一致」。细节见 §8。
3. **向每台主机担保。** 旧设备和每台支持担保的 Mac 有连接时（没有连接就在后台连一次，或等它下次在线），在**已认证的加密连接**上发 `vouchDevice`（新消息 50）。负载是新设备的 `{设备 ID, 名字, 机型, platform, X25519 公钥, 中继成员公钥}`。主机检查以下几条：
   - 主机开着「允许担保」；
   - 请求方已认证，且没被拉黑；
   - 新设备 ID 没被拉黑；
   - 新设备 ID 不在信任表里，或者在表里且公钥相同。公钥不同就拒绝：换钥匙要手动处理，不允许借担保替换。

   通过后主机做四件事：
   - 写进 `.controllers`，另记 `vouchedBy = 请求方 ID` 和 `family`；
   - 请求方此刻勾着公网接入的话，新设备也勾上；
   - 用新设备自己的中继成员公钥签一张成员证书（中继私钥从不离开新设备，需要给 `certificate(for:)` 加一个「签给定公钥」的变体）；
   - 本机发通知「iPhone『…』为 iPad『…』开通了远程控制」。

   最后回 `vouchResult`（新消息 51），内容是 接受 / 主机不允许 / 拒绝，接受时附上证书。
4. **新设备接手。** 旧设备把每台主机的结果写进同步名册里给新设备的那一格：主机的公开信息（ID、名字、公钥、platform、机型）和中继证书（不含私钥）。新设备读到后写进自己的 `.hosts` 表（`ThisDeviceOnly`），中继私钥配上自己那一半，然后照常连接。主机认识它的设备 ID 和公钥，局域网、公网、信令都走现有路径，**握手不用改**。
5. **吊销**
   - 主机端：照旧可以忘记单台设备。新增「连同它担保的设备一起忘记」（按 `vouchedBy` / `family`），列表里显示「由 iPhone『…』添加」。
   - 主控端：在任一台设备上移除丢失的那台，名册里留墓碑。你的其它设备之后连上每台主机时，发 `revokeSibling`（新消息 52）。主机只接受同一 `family` 的设备发来的吊销。吊销只会减少权限，放宽一点没关系，最坏情况是被偷的设备把其它设备都撤掉，你重新配对即可。
   - 中继证书走现有的 `revokeRelayGrant` 和 `RemoteRelayRevocations`。

#### 4.1 为什么担保不会让已配对设备多出权力

一台被允许控制 Mac 的设备，本来就能做到下面两件事：
- 远程桌面打开 uTerm 设置，出一张邀请，再用新设备扫；
- 在那台 Mac 的终端里以用户身份做任何事。

担保只是把这件事做得更顺手、并且**留下记录**：主机知道是谁加的，也能一并撤掉。所以主机端「允许担保」默认打开说得通（见 §6）。权限只能继承、不能放大：新设备的公网接入取决于担保者此刻有没有。

#### 4.2 被控 Mac 是别人的

- 主机端有「允许配对过的设备为自己的其它设备开通」开关，在设置 › 远程控制里。对方关掉后，担保请求一律回「主机不允许」，你的新设备那边显示「这台 Mac 需要单独配对」。
- 每次担保都在对方 Mac 上发通知，设备列表里显示来路，可以一键撤掉整组。
- 公网来的担保请求**不弹审批框**，是否接受只看开关，这一点和现在的公网规则一致。局域网也一样，不另设审批，免得功能变成「远程刷弹窗」。
- 新设备不会看到对方的任何东西，除了主机公开信息和发给它的那张证书。

#### 4.3 协议与兼容

| 组合 | 行为 |
|---|---|
| 新主控端 + 老主机（握手 `features` 里没有 `device-vouch`） | 旧设备跳过这台。新设备显示「这台 Mac 的 uTerm 太旧，需要单独配对」 |
| 老主控端 + 新主机 | 不受影响 |
| 新主机 + 升级窗口里的旧远控进程 | 旧进程不认消息 50，会断开连接。所以必须看能力再发；能力由远控进程自己报，旧进程不报 |
| 旧远控进程重写 `trustedPeers` | 会丢掉 `RemotePeer` 上的新字段。所以 `vouchedBy` / `family` **不要加在 `RemotePeer` 上**，单独存一个账号（如 `peerVouches`），加进 `secretAccounts`。旧进程不碰它，这样也符合 XPC 只加不改 |

其它要点：
- 担保开关经现有的设置快照交给远控进程，加一个可选字段。通知走 XPC 新加的事件 case。
- `RemoteHello`、握手、信令都不改。
- 消息号接着 49 往后编，用 50 / 51 / 52。

#### 4.4 改动量（粗估）

- 共享（`uTerm/Core/Remote/`、`uTerm/Features/Remote/`）：
  - 名册 + 6 位码：约 250 行；
  - 消息 50–52 与主机端处理：约 300 行；
  - 证书「签给定公钥」：约 30 行；
  - 主控端担保任务（逐台连接、写结果）：约 300 行。
- 界面：
  - 两端「我的设备」与确认页；
  - 主机设备列表的来路和整组撤销；
  - 设置开关；
  - 新设备上每台 Mac 的状态（已开通 / 等它上线 / 版本太旧 / 对方不允许）。
- 测试：
  - 主机端规则写成纯函数单测，类似 `RemoteSignalResponder`；
  - `RemoteHostAgentTests` 覆盖远控进程路径和 `persistSecret`；
  - `make test-relay-e2e` 加一例：担保后新设备第一次就经中继连上，不弹审批，证书只能连这台。

### 4.5 对照表

| | (a) 共用私钥 | (b) 账号证书（离线） | (c2) 同步再配对凭据 | **(d) 在线担保** |
|---|---|---|---|---|
| 每台设备钥匙独立 | 否 | 是 | 是 | 是 |
| 丢一台的影响 | 全体换钥匙、全部重配 | 撤这台的证书；根钥匙在丢的那台上就更糟 | 主机撤这台 + 轮换凭据 | 撤这台（或整组） |
| 能单独吊销 | 否 | 能（吊销表要推到主机） | 能 | 能（主机端已有） |
| 钥匙串圈里的攻击者 | 直接冒充 | 根在 iCloud 时能自签 | 直接配对 | 要你在旧设备上点同意且对上码 |
| SE | 永远进不了 | 根钥匙可以进 SE | 不涉及 | 不涉及（以后单设备钥匙可以进 SE） |
| 被控端改协议 | 要（修按 ID 合并的逻辑） | 要（hello、信令、信任表） | 要（长期令牌、信令） | 要（加 3 条消息 + 1 个能力，握手不动） |
| 老主机 | iOS 能用，Mac 不行 | 不能用，退回手动 | 不能用，退回手动 | 不能用，退回手动 |
| 别人的 Mac 看得到、关得掉 | 否 | 要另做 | 部分 | 是（通知、来路、开关） |
| 担保设备要在线 | — | 否 | 否 | 要（后台补做） |
| 改动量 | Mac 中 + 被控端修补 | 大 | 中 | 中 |

## 5. 问题 3：推荐与分期

推荐 (d)，附带 c1（新设备的主机目录本来就是 (d) 的第 4 步）。

| 期 | 内容 | 完成标准 |
|---|---|---|
| P0 设备名册 | 新 service `com.uozi.uTerm.remote.devices`（测试宿主经 `RemoteLocalState.syncedStorage` 隔离）；本机登记 / 撤下；两端「我的设备」列表；先定公钥后出随机数的 6 位码与确认页。**不发任何请求** | 两台真机看到彼此，码对得上；`RemoteLocalStateLintTests` 通过 |
| P1 被控端 | 能力 `device-vouch`；消息 50 / 51；`peerVouches` 账号进 `secretAccounts`；签给定公钥的成员证书；担保开关进设置与快照；通知；设备列表显示来路、整组撤销 | 主机规则单测（拉黑、公钥冲突、开关关、公网继承）；`RemoteHostAgentTests` 覆盖远控进程写回 |
| P2 主控端 | 旧设备的担保任务（逐台连接、后台补做、结果写名册）；新设备接手结果写进 `.hosts` + `relay`；每台 Mac 的状态 | `make test-relay-e2e` 新例；真机：iPhone 担保 → iPad 经蜂窝 + 中继第一次就连上 |
| P3 吊销与收尾 | 消息 52 + 墓碑传播；名册里过期条目清理；（可选）被控 Mac 本人在场时，可以从名册一键批准自己的其它设备（等同局域网审批，但走公网也能用，因为公钥事先已知） | 丢设备演练：撤掉后公网与局域网都拒绝，证书被中继吊销 |

上线前要把 `docs/remote-control-research.md` §16「所有设备都要配对」那条规则改写成「每台设备仍有自己的配对记录，可以由已配对设备在你确认后代办」。这条规则是 user 定的，改之前要 user 点头。

## 6. 已定（2026-11-16，user 按推荐定）

1. **主机端「允许担保」默认开**，每次担保发通知、显示来路，关得掉。
2. **新设备继承担保者此刻的公网接入。**
3. **被担保的设备可以再担保**，同一 `family` 里地位平等，撤销按整组算。
4. **确认放在旧设备上，并比对两台设备的 6 位码。**

## 7. 关键代码位置

- 身份与信任表：[RemoteIdentityStore.swift](../uTerm/Core/Remote/RemoteIdentityStore.swift)（`RemotePeer`、`RemoteTrustRole:49`、`recognizes:178`、`RemoteKeychainStorage:203`、`RemoteLocalDevice:266`）
- 同步存储：[RemoteSyncedStorage.swift](../uTerm/Core/Remote/RemoteSyncedStorage.swift)；测试隔离：[RemoteLocalState.swift](../uTerm/Core/Remote/RemoteLocalState.swift)
- 邀请与旧名册清理：[RemotePairing.swift](../uTerm/Core/Remote/RemotePairing.swift)（`RemotePairingInvitation:18`、`proof:105`、`RemoteLegacyRoster:124`）；删名册的提交 69fea537
- 握手：[RemoteCrypto.swift:15](../uTerm/Core/Remote/RemoteCrypto.swift:15)、`RemoteHello`（[RemoteProtocol.swift:557](../uTerm/Core/Remote/RemoteProtocol.swift:557)），消息号用到 49
- 信令：[RemoteSignaling.swift](../uTerm/Core/Remote/RemoteSignaling.swift)（`RemoteInvitationSignal:141`、`RemoteSignalResponder:192`）
- 被控端认人：[RemoteHostConnection.swift](../uTerm/Features/Remote/RemoteHostConnection.swift)（`handshake:145`、`authorizeFromInternet:216`、`newPeer:252`）；[RemoteHostServer.swift](../uTerm/Features/Remote/RemoteHostServer.swift)（`knownPeer:294`、`connectedControllers:425`、`fileConnection:455`、`makePairingInvitation:516`、`redeemPairingProof:554`、`trust:643`）
- 远控进程交接：`RemoteHostAgentBridge.secretAccounts`（[RemoteHostAgentBridge.swift:318](../uTerm/Features/Remote/RemoteHostAgentBridge.swift:318)）、`persistSecret` / `grantInternetAccess`（[RemoteHostAgentProtocol.swift:254](../uTerm/Features/Remote/Agent/RemoteHostAgentProtocol.swift:254)）
- 主控端：[RemoteMacClient.swift](../uTerm/Core/Remote/RemoteMacClient.swift)（核对 `:497`、`handlePairing:589`、`forget:634`）、[RemoteMacDirectory.swift](../uTerm/Features/Remote/RemoteMacDirectory.swift)
- 中继证书与放置：[RemoteRelayConfig.swift](../uTerm/Core/Remote/RemoteRelayConfig.swift)（`certificate(for:):94`、`RemoteRelayPlacement:211`、默认中继同步存储 `:241`）
- 公网接入与共享文件夹的偏好键：`DefaultsKey.remoteInternetDevices` / `remoteSharedFolders` / `remoteDeviceID`
- 解锁密码：`uTermMobile/Screens/Remote/RemoteUnlockVault.swift`（只存手机，不在同步范围内）

## 8. P0 落地（分支 `claude/remote-device-roster`）

只做名册与确认，不发任何请求，被控端一行没改。确认过的设备还不能替谁开通 Mac（P1、P2）。

### 名册

- iCloud 钥匙串 service `com.uozi.uTerm.remote.devices`（`RemoteSiblingRoster`），经 `RemoteLocalState.syncedStorage` 取：测试宿主里是内存的一份。
- 每条记录外面包 `{"v":1,"record":…}`。`v` 不认识、记录类型不认识、公钥不是 32 字节的一律跳过（名册谁都能写）。
- 记录有两种：
  - `device.<设备 ID>`：`RemoteSiblingDevice`，即设备 ID、名字、机型、platform、远控长期公钥、登记时间。内容没变就不重写。
  - `<kind>.<新设备>.<已有设备>`：`RemoteSiblingMessage`，确认时两台设备之间的消息（下一节）。
- 启动时登记本机（`RemoteSiblingRoster.registerLocalDevice()`，两端 `App.init`，测试宿主里不做）。登记**只读不生成**身份（新加的 `RemoteIdentityStore.existingIdentity()`）。启动时目录或被控端可能正在第一次生成身份，两个 store 同时 `localIdentity()` 会各生成一把，后存的顶掉先存的。还没身份就等打开「我的设备」时再登记。

### 确认（`RemoteSiblingDevices`，两端共用）

1. 新设备对名册里每台已有设备写 `commitment` = SHA256(用途 ‖ 新设备 ID ‖ 新设备公钥 ‖ 已有设备 ID ‖ 已有设备公钥 ‖ rn)，rn 是 16 字节随机数，存本机（`RemoteSiblingLocalStore`，账号 `siblingCommits`）。
2. 已有设备上点「确认…」：记下对方此刻的承诺，写 `challenge`（ro）。对方还没承诺就等着，不出随机数。
3. 新设备看到发给自己、两边公钥都对得上的 `challenge`，写 `reveal` = rn ‖ ro（带上 ro，已有设备只认答它这一次的 reveal），显示 6 位数，然后换一个 rn 重新承诺。答过的那次记在本机：App 重开后显示同一个数，也不会对同一次确认答第二次。
4. 已有设备核对 rn 与记下的承诺。对不上就停（「可能有别的设备冒充它」）；对得上就显示 6 位数 = SHA256(用途 ‖ 两边身份 ‖ rn ‖ ro) 前 4 字节模一百万。
5. 你点「一致」：确认结果记在**已有设备本机**（`siblingApprovals`，`ThisDeviceOnly`，按设备 ID + 公钥），然后删掉 `challenge` / `reveal`。点「不一致」或「取消」什么都不记。确认是单向的。

其它规则：
- 等 5 分钟没回应就停。对方中途换了钥匙或被移出名单也停。
- App 重开后，本机上次发出的 `challenge` 一律清掉：ro 只在内存里，接不上。
- 对方换了钥匙（重装过）显示「要重新确认」。
- 「从名单移除」删掉它的条目和相关消息；它下次打开 uTerm 会重新登记，要重新确认。

只在「我的设备」开着时每 2 秒读一次名册，两台设备都要打开这一页。iCloud 钥匙串同步要几秒到几十秒，所以一次确认要两三个同步来回。

### 冒充者能做到的（用例都钉住了）

- 登记一台同名设备：列表里是两台，各自确认。你点了它的「确认…」，它能答到显示数字这一步，但你手里的真设备上什么数都不显示。
- 抢先写 reveal：答出的随机数与承诺对不上，确认停止。
- 伪造 challenge 发给真设备：真设备显示一个数，但已有设备没在确认，什么也不会记。
- 写「已确认」：做不到，确认结果不在名册里。

### 界面

- Mac：设置 › 远程控制最下面一组「我的设备」（`RemoteMyDevicesGroup`，mac-only，已加进 iOS 的 `membershipExceptions`）。
- iOS：设置 › 远程控制 › 我的设备（`RemoteMyDevicesScreen`）。
- 文案在共享的 `RemoteSiblingCopy` 与 `Row.subtitle`。

### 测试

`uTermTests/Core/Remote/RemoteSiblingTests.swift`：记录往返与坏记录、核对码绑定两边身份与两个随机数、完整确认、确认只存本机、不一致不记、重开后同一个数且不答两次、答后换承诺、四种冒充、换钥匙（事后与中途）、移除后重新出现、超时、对方未承诺先等、残留 challenge 清理、登记只在变化时重写、`existingIdentity` 不生成。

### 留给后面

- 名册条目里还没有中继成员公钥（P1 签证书时加，字段可选，P0 的条目重新登记即补上）。
- 吊销传播和墓碑（P3）。
- 真机两台设备经 iCloud 钥匙串走一遍还没做，同步延迟没量。

## 9. P1 落地：被控端（同一分支）

被控端认得担保请求，主控端能发；谁、什么时候去发（P2）还没做，所以用户此刻看到的只有设置里的开关和来路。

### 协议

- 能力 `device-vouch`（`RemoteFeature.deviceVouch`，加进 `RemoteConstants.localFeatures`）。老 Mac 不报它，主控端直接报「版本太旧」，**不发**消息（老 Mac 收到未知消息会断开整条连接）。
- 消息 50 `vouchDevice`（主控端 → Mac，通道 0，`RemoteVouchRequest`：请求号、设备 ID、名字、机型、platform、X25519 公钥）。
- 消息 51 `vouchResult`（`RemoteVouchResult`）：
  - `outcome` 用字符串存，以后多一种结果老版本照样解得开。取值有 `added` / `already-trusted` / `not-allowed` / `rejected`。
  - 另带 `reason`、`internetAccess`、`relay`。
- 只在已认证的连接上处理（`handle` 开头的门禁），局域网和公网连接都行。握手、信令都没改。
- 纯数据与规则在 `uTerm/Core/Remote/RemoteVouch.swift`，三个 target 都编（加进了远控进程的 `membershipExceptions`）。

### Mac 怎么判（`RemoteVouchPolicy.decide`）

按顺序：
1. 担保自己或这台 Mac：拒绝。
2. 公钥不是合法的 X25519，或名字是空的：拒绝。
3. 已经认识这台设备：公钥相同回 `already-trusted`，什么都不改；公钥不同就拒绝，要到 Mac 上重新配对，不能借担保换钥匙。
4. Mac 上撤销过（拉黑）的设备：拒绝。撤销是 Mac 主人的决定，不能借担保回来。
5. 开关关着：`not-allowed`。
6. 以上都不是：记下。

记下时：
- 先写来路 `RemotePeerVouch`（新设备、担保者、组号、时间），再写信任表。
- 担保者此刻能经公网接入，新设备才勾上，并按 `relayConfig(forPeer:)` 给它发自己的一张中继成员证书。
- 组号沿用担保者的组号；担保者是手动配对的，组号就是它自己的 ID。

### 和调研时的设想不同的一处：中继证书仍由 Mac 生成钥匙

§4 里打算让新设备自己生成中继成员钥匙、Mac 只签公钥。实际做法和邀请一样：Mac 生成成员钥匙、签证书，私钥随结果交给担保者，P2 再由担保者经 iCloud 钥匙串交给新设备。原因：
- 现有的续期（`renewed(by:)`）、吊销（`memberPublicKey`）都从证书里的私钥推公钥。改成只有公钥，要动中继证书这一整套。
- 邀请本来就把成员私钥放在二维码和链接里交出去，经 iCloud 钥匙串（端到端加密）交并不比它差。
- 这张证书只能连这一台 Mac 的中继，进不了加密会话，还得过信任表。

### 来路记录

- 存在被控端身份存储的新账号 `peerVouches`（`RemoteIdentityStore.vouchAccount`），已加进 `RemoteHostAgentBridge.secretAccounts`。
- 不放在 `RemotePeer` 上：升级窗口里旧远控进程重写 `trustedPeers` 会丢掉它不认识的字段，旧进程不碰新账号。
- 撤销一台设备时，它的来路记录一并去掉（`RemoteIdentityStore.revoke`）。

### 开关与通知

- 设置 › 远程控制 › 已配对的设备，「允许已配对的设备开通主人的其它设备」（`RemoteControlSettings.isDeviceVouchingEnabled`，`DefaultsKey.remoteDeviceVouching` = `remote.deviceVouching`，默认开）。
  - 交给远控进程的设置快照加了可选字段 `deviceVouching`：老 App 交来的设置没有这个键，按默认（开）算。
  - 关掉以后，已经开通的设备不受影响。
- 通知：`RemoteVouchNotifier`（mac-only）发「『iPhone』为『iPad』开通了远程控制」。**不加新的 XPC 消息**：
  - 远控进程担保后，信任表和来路照常经 `persistSecret` 写回。
  - App 在 `agentPersistedIdentity()` 里比对出新的来路记录，回调 `onDeviceVouched`。
  - 进程内服务时由 `handleVouch` 直接回调。
- 设备列表的副标题多「由『iPhone』添加」。同一组超过一台时，菜单多「撤销同一组的 N 台设备…」（`revokeFamily`，远控进程在服务时逐台转过去）。
- 「已配对的设备」那组的说明改了：同一 Apple ID 本身不算数，但可以由已配对的设备替它开通。

### 主控端

`RemoteMacClient.vouch(for: RemoteSiblingDevice)`：先看 `supportsDeviceVouch`，再发 50，按请求号等 51；连接断了抛 `closed`。

### 测试

- `RemoteVouchTests`：
  - 8 条规则：允许、开关关、撤销过、换钥匙或已认识、自己和非法身份、组号与组员、未知结果能解、来路是独立账号。
  - 7 条真服务端 + 真客户端：担保后新设备免审批连上，且只通知一次；开关关掉什么都不记；撤销过的担保不回来；不能换钥匙；公网只继承不放大；老 Mac 不发；被担保者再担保同组、整组撤销后连着的组员断开、别人不受影响。
- `RemoteHostAgentTests.test_vouch_handled_by_the_agent_is_written_back_and_notified_in_the_app`：远控进程里担保 → 信任表与来路写回 App → App 发一次通知 → 新设备连远控进程不弹审批 → App 里关掉开关，远控进程跟着拒绝。
- 远控相关 14 组 147 例回归全过。

### 留给 P2

- 旧设备对「我的设备」里确认过的设备，逐台向配对过的 Mac 发担保（后台补做，连接失败或 Mac 不在线时下次再试）。
- 把结果（主机公开信息、证书）经 iCloud 钥匙串交给新设备；新设备写进 `.hosts` 和 `relay`。
- 新设备上每台 Mac 的状态。

## 10. P2 落地：主控端开通（同一分支）

到这一步整条链路走得通：iPhone 确认 iPad → iPhone 逐台向它配对过的 Mac 担保 → 结果封好经 iCloud 钥匙串交给 iPad → iPad 把这些 Mac 记进自己的信任表 → iPad 照常连接，Mac 不弹审批。

### 和 P0 不同的一处：新设备上也要点「一致」

开通结果里有 Mac 的身份，新设备收下后会去连它、往它的终端里打字。如果新设备不核对是谁送来的，钥匙串圈里的人就能封一条假结果，让它去连一台冒充的「Mac」。所以：
- 新设备显示 6 位数时多了「一致 / 不一致」。点「一致」，本机记下这台担保者和它当时的公钥（`RemoteSiblingLocalStore.trustedVouchers`，账号 `siblingVouchers`，`ThisDeviceOnly`）。
- 新设备只收这些担保者封的结果。
- 两台都点「一致」，确认才算双向完成。
- 点「不一致」只是不再显示这个数，什么都不记。

### 开通结果

- 名册里一种新记录 `grant.<新设备>.<担保者>.<Mac>`（`RemoteSiblingSealedGrant`）。P0 的版本不认这种记录，读到直接跳过。
- 内容 `RemoteSiblingGrant` 用 ChaChaPoly 封：
  - 钥匙 = HKDF(X25519(担保者私钥, 新设备公钥))，只有这两台算得出来（`RemoteSiblingSeal`）。
  - AAD 绑定新设备、担保者、Mac 三个 ID：一条结果不能被搬成另一台 Mac 的，也不能搬给另一台设备。
  - 封起来也顺带护住了里面的中继成员证书。
- 内容有 Mac 的公开身份、结果（`added` / `already-trusted` / `not-allowed` / `rejected`，再加 `unsupported` 表示 Mac 太旧）、原因、公网接入，以及中继。中继取 Mac 发的成员证书；没有证书时，取担保者给这台 Mac 单独记的、不是证书的中继。默认中继新设备经 iCloud 钥匙串本来就有。

### 已有设备怎么问（`RemoteSiblingDevices+Grants.swift`）

- 范围是本机确认过（且钥匙没变）的设备 × 本机配对过、此刻在线的 Mac。
- 一次只问一台 Mac，在「我的设备」页面开着时做。页面挂着 `keepLiveStatusFresh`，Mac 上还会开局域网浏览（iOS 不替用户打开，免得弹本地网络授权框）。
- 连不上不写结果，60 秒后再问。
- 记下了、已认识、拒绝：不再问。
- 不允许、太旧：6 小时后再问（Mac 的主人可能打开开关、更新 uTerm）。
- Mac 换了钥匙：重新问。
- 取消确认后不再替那台设备问。
- 连接的用法：已经开着这台 Mac 的连接就借用；没开时，Mac 上按窗口计数临时取一条、问完放掉；iOS 上用目录的客户端，留着等退后台时一起收（iOS 的目录不计数，放掉会断开正在用的连接）。
- 列表里确认过的设备，副标题显示「已替它开通 N 台 Mac · M 台等上线 · K 台没开通」。

### 新设备怎么收（`RemoteMacDirectory.adopt`）

- 时机：「我的设备」页面开着时；两端启动时也收一次（`receivePendingGrants`，只读名册、不连网；iOS 放到启动之后的下一拍）。
- 本机没记过这台 Mac：记进信任表，中继按 `RemoteRelayPlacement` 放。不替用户打开局域网浏览。
- 本机记过、公钥相同：本机还没有这台的中继时补上。
- 本机记过、公钥不同：不覆盖（显示「身份不一样，没有改动」）。
- 本机忘记过（拉黑）：不加回来。那是在这台设备上做的决定。
- 「替这台设备开通的 Mac」一组列出每台 Mac 的状态。

### 其它

- Mac 设置窗的环境里加了 `RemoteMacDirectory`。
- 「远程控制」最上面那段说明改了：同一 Apple ID 本身不算数，可以由已配对的设备开通。
- 测试夹具 `SettingsPageSnapshotTests` 补了 `RemoteMacDirectory` 和 `TerminalSessionRegistry`。后一个是 main 上早就缺的：公网接入那一组读它，打开截图开关就崩。

### 测试

- `RemoteSiblingGrantTests`（10 例）：
  - 封装只在两台之间打得开、搬不走；
  - 逐台问、新设备收下、问过的不再问；
  - 新设备没点「一致」什么都不收；
  - 点「不一致」只隐藏；
  - 冒充者封的、冒用担保者 ID 的结果都不收；
  - 太旧的告诉新设备且几小时内不再问，连不上的一分钟后再问；
  - Mac 换钥匙重问；
  - 只替确认过的设备问；
  - 目录收下的四种情况；
  - 真服务端端到端：iPhone 审批配对 → 确认 iPad → 担保 → iPad 收下 → iPad 连 Mac 不弹审批。
- 远控相关 22 组 245 例回归全过；设置页截图用例打开开关跑过、出图核过。
- 真机两台经 iCloud 钥匙串还没走过，同步延迟没量。

### 留给 P3

- 移除一台丢失的设备：传到各台 Mac（消息 52 + 墓碑）。
- 名册里过期记录清理。
- （可选）被控 Mac 本人在场时，从名册一键批准自己的其它设备。

## 11. P3 落地：丢了的设备、清理（同一分支）

### 「这台设备丢了」

- 在任一台设备的「我的设备」里，对某台设备点「这台设备丢了…」（要确认）。名册里写一块墓碑 `tombstone.<设备 ID>`（`RemoteSiblingTombstone`：设备 ID、名字、**公钥**、报告者、时间）。
- 你所有的设备看到墓碑后：
  - 撤掉对它的确认（不再替它开通）和对它当担保者的认可（不再收它送来的结果）；
  - 删掉它在名册里的往来消息和开通结果。条目留着，列表里不显示它（只在「已丢失」里）；取消报告后它马上回到名单，不用等它自己重新登记（2026-11-16 走查：原先连条目一起删，取消后要等丢了那台下一轮登记，设备会消失一会儿）；
  - 列表里把它挪进「报告丢失的设备」。
- 丢了的那台自己看到墓碑：不再登记、不回答确认、不替谁开通，页面上提示它被报告丢失（`localReportedLost`）。
- 墓碑按公钥记：找回来重装过（换了钥匙）的同一台设备不受影响，但要重新确认。
- 「找回来了，取消报告」撤下墓碑。已经撤掉的 Mac 不会自己恢复，那台设备要重新开通或到 Mac 上配对。
- 墓碑留 90 天，到期任何一台设备都会清掉。
- 谁都能写墓碑，但它只会减少信任：最坏是被偷的那台把你别的设备也报成丢了，重新确认、配对即可。

### 请各台 Mac 撤销

- 协议：能力 `sibling-revoke`；消息 52 `revokeSibling`（`RemoteSiblingRevokeRequest`：请求号、设备 ID、公钥）和 53 `revokeSiblingResult`（`revoked` / `not-trusted` / `not-in-family`，用字符串存）。老 Mac 不报这一项就不发，记成「版本太旧」。
- Mac 怎么判（`RemoteVouchPolicy.decideRevoke`）：
  - Mac 记着的这台的公钥和请求里的不一样，或根本不信任它：`not-trusted`，什么都不改。它可能后来重新配对过。
  - 请求方和被撤的那台在这台 Mac 上不是同一组：`not-in-family`。各自手动配对的设备，Mac 没有凭据说它们属于同一个人，只能到 Mac 上撤。
  - 否则撤销：效果同设置里的「撤销配对」，即断开、拉黑、吊销它的中继证书。撤自己也行。
- 不看「允许担保」开关：撤销只会减少信任。
- 撤销放到下一拍做：撤的可能是发请求的那台自己，先把结果发出去。
- 主控端：`RemoteMacClient.revokeSibling(_:publicKey:)`。所有设备都可以去撤，在「我的设备」页面开着时进行，和开通共用「一次只问一台」的槽位，撤销优先。
  - 进度记在本机（`RemoteSiblingLocalStore.revocations`，账号 `siblingRevocations`）。
  - 撤掉了、不信任、不同组的不再问；版本太旧的 6 小时后再问；连不上的 60 秒后再问。
  - 「报告丢失的设备」里每台显示「已从 N 台 Mac 撤销 · M 台等上线 · K 台要到 Mac 上撤销：…」。

### 清理

- 新设备：确认被对方放弃（challenge 没了），自己留在名册里的回答也删掉。
- 已有设备：本机已经不再配对的 Mac，本机替别的设备写过的开通结果删掉。
- 已经有的清理（P0）：App 重开时清本机发出的 challenge；名册里没了的设备，清本机给它的承诺。
- 设备条目本身不按时间过期：条目只在名字、钥匙变了才重写，时间旧不代表设备不用了。不用的设备在列表里手动「从名单移除」。

### 没做

被控 Mac 的主人在场时，从名册一键批准自己的其它设备（§5 里标的可选项）。眼下 Mac 上已经有扫码、审批、担保三条路，这一条等真机用一阵再看要不要。

### 测试

- `RemoteVouchTests`：撤销规则（同组、撤自己、别组、换过钥匙、不信任、组号就是根设备）；真服务端上别组撤不了、同组撤掉后断开且不能借担保回来、老 Mac 不发。
- `RemoteSiblingGrantTests`：
  - 报告丢失后各台设备去掉它、不再替它开通、逐台撤销（成功、太旧几小时后重问、不同组记下原因），丢了的那台不再登记；
  - 重装后换了钥匙的不受影响，可以取消报告；
  - 墓碑过期；
  - 清理残留回答与不再配对的 Mac 的开通结果。
- 远控相关 22 组 252 例回归全过；两端编译通过；已跑 `make sync-strings`。

## 12. 真机走查与之后的改动（2026-11-16）

### 走查（build 1196，三台真机）

被控端是本机 MacBook，担保者是 iPhone Duo，新设备是 Mac mini。确认、开通（16:28，公网接入从 Duo 继承）、mini 免审批直连（16:29）、报告丢失后本机撤销 mini（16:32）全部通过。

发现两个问题：
- 新设备上的核对码只显示在设置页最底下。Duo 一直显示「正在确认…」，user 以为卡住了。另外，新设备不打开那一页就根本不回应。
- 本机的开通通知发出去了，但被专注模式静音（系统日志 `muted by DND suppression`），只进了通知中心。这是系统行为，不是 bug。

### 改动：确认改成单独弹窗 + 输入核对码（user 定）

- **全 App 只有一个**：`RemoteSiblingService`（App 级单例，Mac 一直跑，iOS 只在前台跑）在后台定时调 `RemoteSiblingDevices.refresh()`，空闲 10 秒一次，有人在看或有确认在进行时 2 秒一次。页面不再自己建模型、也不再自己轮询。两个实例同时跑会互相清掉对方发出的 challenge，所以只能有一个。后台从不生成身份，打开「我的设备」时才生成。
- **新设备一侧弹窗**：Mac 是独立面板 `RemoteSiblingPrompt`（同配对审批面板，没开窗口也能弹）；iOS 是根视图上的单子 `RemoteSiblingConfirmHandler`，不能下滑关掉。弹窗显示 6 位数，请你在那台设备上输入，同时给「允许 / 拒绝」。点「允许」弹窗马上关，新设备在后台等那条「核对通过」，收到就自动记下担保者（本机钥匙串里记着点过「允许」的那一次的 challenge，`RemoteSiblingCommitState.acceptedChallenge`；换一次确认要重新点）。先后不论，两样都要有才算数。那边先输对的话，点「允许」时直接记下。（2026-11-16 走查：原先要等「核对通过」经 iCloud 钥匙串同步到了才出「允许」，同步慢时弹窗挂很久。）点了「允许」还没收到「核对通过」、或刚认可担保者 5 分钟内（在等开通结果），新设备按 2 秒一轮读名册（`isAwaitingOthers`），不退回 10 秒；已有设备输对码后马上去问 Mac，不等下一轮。每条别的设备写给本机的记录（确认请求、回答、核对通过、开通结果）第一次读到时记一行 notice「写入后 N 秒读到」（按写入方时钟，含两台时钟差），量 iCloud 钥匙串一跳的实际耗时：`log show --predicate 'eventMessage CONTAINS "写入后"'`。设置页里不再显示这一块。
- **已有设备输入，不显示**：已有设备（点「确认…」的那台）不显示核对码，只给输入框（`RemoteSiblingDevices.submitCode`）。输错 3 次停止。人必须真的抄一遍，不会看都不看就点「一致」。
- **在做信任决定的那一端输入**：
  - 已有设备输对了，才记下新设备（替它开通）。
  - 已有设备输对后写一条「核对通过」（`RemoteSiblingMessage.Kind.confirmed`）：用两台设备长期钥匙协商出的密钥封，绑定这一次的 challenge 随机数。新设备打得开、并且是这一次的，才算核对通过。核对通过且新设备点了「允许」，才收这台设备送来的开通结果。
  - 冒充者做不出「核对通过」，旧的也搬不过来。
  - 反过来设计不行：如果在新设备上输入、再由新设备告诉旧设备「对上了」，冒充者自己发一句「对上了」就能让旧设备记下它。
- **为什么不用真随机码当 OTP**：名册经 iCloud 钥匙串同步，钥匙串圈里的人能看到用这个码算出的凭据，离线试遍 6 位数只要几秒。要安全得用 PAKE（口令认证密钥交换），CryptoKit 不提供。现在的核对码由两端的承诺和随机数算出，改成「一端显示、另一端输入」后安全性不变，线上只多了 `confirmed` 一种消息。P0–P3 的版本不认这种消息，读到会跳过。
- **配对审批也改成输入**：主控端（手机或 Mac）显示 6 位数；被控 Mac 的审批面板改成输入框，输对就等于点了「允许」，输错 3 次或点「拒绝」就是拒绝（`RemotePairingPanel`，文案在 `RemotePairingCopy`）。握手协议不变。

### 梳理授权界面

另一份方案 `docs/remote-settings-ia.md`（agent 写的，未落地）建议把「我的设备」挪出被控页、文案大幅缩短、合并重复的设备列表。这一轮只做了上面的弹窗和输入，其余按那份方案另做，需要 user 拍板的问题在它的 §5。

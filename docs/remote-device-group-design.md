# 设备组：重新设计「我的设备」（方案，2026-11-16）

接 `docs/remote-shared-pairing-research.md`。那份文档的 P0–P3 已在 main，弹窗和输入核对码在分支 `claude/sibling-confirm-popup`。三台真机走查后 user 的结论：实际操作十分混乱，要重新设计；同一个账号加入授权之后，设备之间不用再互相匹配。

方案 2026-11-16 定稿（§10），按 §11 分期实施，落地情况记在文末。

## 结论

把「两台设备互相确认」换成「加入设备组」：

- 一台设备只加入一次，和组里**任意一台**设备核对一个 6 位数。
- 加入后它就是组员：组里每台设备配对过的 Mac，所有组员都能用；之后再加设备，已有组员不用做任何事。
- 界面只剩一份组员名单和两个操作：添加、移除。
- 被控端协议基本不动（消息 50–53 照用），只改一条规则：被同组设备撤销的设备不进黑名单。

## 1. 现在为什么乱

现在的信任是**一对一、单方向**的：A 确认 B，只表示 A 把自己的 Mac 开通给 B。

- 三台设备有 6 个方向，每个方向各确认一次；mini 的 Mac 要给 Duo 用，还得反过来再确认一次。
- 每次确认要两端各操作：一端发起、输码，另一端看弹窗、点「允许」。
- 每台设备的一行里叠着三层状态：确认状态（未确认 / 已确认 / 重装过）、它是不是本机认可的担保者、它在每台 Mac 上的开通进度（已开通 / 被拒 / 等待）。
- 另有两个区：别的设备替本机开通的 Mac（5 种状态）、已丢失的设备（每台 Mac 的撤销进度）。
- 「这台设备丢了」可以取消，但取消后 Mac 上的撤销不恢复，开通还会被 Mac 拒绝（走查时遇到的那次）。

## 2. 新模型：设备组

- **设备组**：你确认过属于自己的一组设备。一台设备要么在组里，要么不在，没有中间状态。
- **加入**：新设备和组里任意一台设备核对一次。核对是双向的：组认识了新设备，新设备也认识了整个组。
- **组员权力相同**：任何组员都能添加设备、移除设备、替别的组员向 Mac 开通。这和现在「被担保者可再担保」的决定一致。
- **没有「建组」这一步**：每台设备一开始是只有自己的组。两台都没有组的设备核对一次，就成了一个两台设备的组。
- 已经在别的组里的设备加入另一个组时，只有它自己过去，原来组里的设备不跟着走。

不变的原则：

- 同一 Apple ID 本身不构成信任，iCloud 钥匙串只当传话的通道。每台设备进组都要你亲手核对一次。
- 被控的远控进程不读名册。
- 每台设备的远控身份（X25519 私钥）仍然只在本机。

## 3. 加入（每台设备一次）

推荐的流程（方案 C，见下）：

1. 新设备上：设置 › 远程控制 › 我的设备 › 「加入」。屏幕上立刻显示一个 6 位数。
2. 任意一台组员上：弹出「「Mac mini」想加入你的设备。输入它显示的 6 位数」。输入。
3. 完成。新设备上的数字消失，显示「已加入」。

两端各一个动作，中间不需要你再点什么。输错 3 次这次作废；新设备上的数只能被试一次，试错就换一个新数。

### 三种核对方式

| | A. 沿用现在的核对码 | B. 扫二维码 | C. 真正的一次性码（推荐） |
| --- | --- | --- | --- |
| 你的操作 | 新设备点「加入」并选一台组员；组员上输码；新设备上看到对方显示通过后点「完成」 | 一端显示二维码，另一端用摄像头扫 | 新设备点「加入」；组员上输码 |
| 两端都验明对方吗 | 组员一侧是。新设备一侧靠你确认「对方显示通过了」 | 是 | 是 |
| 码显示前要等同步吗 | 要，两跳 | 不要 | 不要 |
| 输码后到新设备加入 | 一跳 | 一跳 | 一跳 |
| Mac 和 Mac 之间能用吗 | 能 | 不方便（要举着电脑扫） | 能 |
| 新写的密码学代码 | 无 | 无 | 有：CPace 的曲线映射，约 150 行，照 IRTF 草案的测试向量核对 |

为什么 A 的新设备一侧弱：6 位数是从两端的随机数算出来的，对方设备自己也算得出。所以「对方说核对通过」不能证明有人在真设备上输过码；钥匙串圈里的冒充者可以给自己写一条「通过」。现在的流程靠新设备上再点一次「允许」补这一环，补得不牢（见文末「分支里的问题」）。

C 的做法：6 位数由新设备随机生成，只出现在它的屏幕上。两端用 CPace（一种口令认证密钥交换）证明彼此知道这个数，冒充者每次只能猜一次，猜中概率百万分之一。它需要的椭圆曲线运算 CryptoKit 能做大部分（X25519），缺一步「把哈希映射到曲线上」要自己写。

**C 还没验证的两点**（动手前先做一个半天的探针）：
- CryptoKit 的 X25519 能否拿任意点当基点做乘法、结果为零时是否报错。
- 自己写的映射能否通过 IRTF 草案（draft-irtf-cfrg-cpace）的测试向量。

探针不过就退到 A。B 可以以后作为手机端的快捷方式加上，不是必需。

## 4. 加入之后：Mac 自动通

- **组里共用一份 Mac 目录**：每台组员把自己配对过的 Mac（ID、名字、公钥、机型）写进组的共享记录。新组员加入的那一刻就拿到整份目录，「我的 Mac」里马上列出来。
- **开通由在线的组员自动做**：任何一台组员只要连得上某台 Mac、而且那台 Mac 认它，就替还没开通的组员向它担保（现有的消息 50 / 51）。
  - 加入完成时，负责核对的那台组员立刻并行去问它连得上的所有 Mac，不再一次只问一台。
  - 新组员被某台 Mac 认了以后，自己也能替别的组员担保，所以不依赖某一台设备在线。
- **新设备不用等结果同步**：它已经有 Mac 的地址和公钥，直接去连。Mac 已经认它就连上；还没认就显示「正在开通」，过一会儿自动好。
- **公网接入**：Mac 发的中继成员证书仍然只给那一台设备，由担保的组员封给它（现有做法）。
- **Mac 关了「允许担保」或版本太旧**：那台 Mac 的行上写原因（「这台 Mac 要单独配对」），不影响别的。

「我的设备」里不再有「每台设备 × 每台 Mac」的进度。一台 Mac 对**这台设备**通没通，写在「我的 Mac」里那台 Mac 的行上。

### 组里的 Mac 互相控制（要你定）

组员里的 Mac 自己也可能是被控端。建议：**Mac 进组后，自动认组里别的设备当主控端**，不用再各自配对一遍。这是「不用再互相匹配」最自然的意思：Duo 和 MacBook 进了组，就都能控制同在组里的 mini。

- 由 App 在本机做（等于自己给自己担保一次），远控进程照旧不读名册。
- 受 Mac 上已有的那个开关管；来路记成「设备组」，可以单独撤掉。

## 5. 移除

只有一个操作：**「从我的设备中移除」**。换掉旧设备、设备丢了都用它。

- 组里所有设备马上不再认它，也不再替它开通。
- 组员逐台请 Mac 撤销它（现有的消息 52 / 53）。
- 移除时列出「它加进来的设备」，默认一起移除（设备被偷后，小偷可能用它加过别的设备）。
- **没有「取消报告」**。设备找回来了，就重新加入一次（一个码），Mac 随后自动重新开通。
- 被移除的设备自己显示「这台设备已被移出」，不再参与。

为了让「重新加入后自动开通」成立，被控端要改一条规则，见 §8。

## 6. 界面

**设置 › 远程控制 › 我的设备**

- 还没进组：
  - 一句说明：加入后，你在任何一台设备上配对过的 Mac，这台设备都能用。
  - 你的其它设备的名字，和一个「加入」按钮。
  - 没有其它设备时：提示在另一台登录同一 Apple ID 的设备上打开 uTerm。
- 已进组：
  - 组员名单：名字、机型、「这台设备」标记。每行只有一个操作「移除…」。
  - 名单下方列出还没进组的设备，带「添加」（等于打开输码框，给弹窗被关掉时用）。

**弹窗**

- 新设备：点「加入」后显示 6 位数和「取消」。
- 组员：有设备想加入时弹输码框，带「拒绝」。任意一台组员输对即可，别的组员上的弹窗自动关掉。

**我的 Mac**

- 组里的 Mac 自动出现。还没通的那台，行上写「正在开通」或原因。

删掉的东西：确认 / 取消确认、认可的担保者、开通进度矩阵、「收到的 Mac」区、「已丢失」区和取消报告、新设备上的「允许」。

## 7. 机制

- **组员凭证**：每台设备新增一把 Ed25519 签名钥匙（只在本机）。加入时核对的内容同时绑定它的 X25519 身份和这把签名钥匙。
- **名册里的记录**（iCloud 钥匙串，签名保证真伪，不靠钥匙串圈）：
  - `admit`：「D 是组员」，由一台组员签。
  - `remove`：「D 被移除」，由一台组员签。
  - `host`：一台 Mac 的目录项，由配对过它的组员签。
  - `grant`：某台 Mac 发给某台组员的中继证书，封给那台组员。
  - `join`：新设备的加入请求（不需要签，靠核对码验）。
- **每台设备本机存一份「我认的组员」**（只在本机）：
  - 加入时，从核对的那台组员拿到当时的整份名单。
  - 之后每轮读名册：先处理 `remove`，再处理 `admit`；只认签名者是「我认的组员」的记录。
  - 一台设备被移除后，它签的新记录不再认；它以前加进来、我已经认了的设备不受影响（除非一并移除）。
- **不用组密钥**：考虑过全组共用一把对称密钥，但移除设备时要换钥匙、再分发给每台组员，两台设备同时换还会冲突。签名记录没有这些问题。
- **冒充者（在钥匙串圈里、没有任何组员私钥）能做的**：写假的设备条目和加入请求。假请求会让组员弹输码框，但没有真设备屏幕上的数，过不了。它写不出组员签名，改不了名单和 Mac 目录。
- **被偷的组员设备（移除之前）能做的**：加别的设备、移除别的组员、向 Mac 撤销别的组员。和现在一样，最坏是你把设备重新加一遍；所以移除时默认连它加进来的设备一起移除。
- **同步速度**：每一跳仍是 iCloud 钥匙串。方案 C 下，输码前不用等同步，输码后一跳新设备就进组。两台设备在同一个局域网时再走一条直连通道（已有的局域网同步那套 Bonjour），可以以后加，不是必需。

### 7.1 规格（实施照这一节，G0 之后定）

**探针结果（G0，`CPace.swift`，60651a59）**：两点都成立。CryptoKit 的 X25519 接受任意 32 字节当基点，结果为零时抛错；自己写的 Elligator2 和生成元计算逐字节对上 draft-irtf-cfrg-cpace-21 与 RFC 9380 的向量。核对方式用 C。

**存哪**

- 名册：iCloud 钥匙串新 service `com.uozi.uTerm.remote.group`（`RemoteSyncedStorage`）。旧的 `com.uozi.uTerm.remote.devices` 不再读，启动时清掉本机写过的记录。
- 本机（`RemoteSecretStorage`，只在本机）：Ed25519 签名私钥、「我认的组员」、移除记录、待确认的加入。

**记录**（信封同旧名册：`{v:1, record:…}`，解不开的当没有）

| account | 内容 | 谁写 | 真伪靠什么 |
| --- | --- | --- | --- |
| `device.<id>` | 设备 ID、名字、机型、platform、X25519 公钥、Ed25519 公钥 | 自己 | 不保证（只用来列出「你的其它设备」） |
| `join.<新设备>` | 新设备的条目、`sid`（16 字节随机）、CPace 份额 Ya、时间 | 新设备 | 核对码 |
| `answer.<新设备>.<组员>` | 组员的条目、份额 Yb、确认标签 Tb、用会话密钥封的入组包 | 输码的组员 | 核对码 |
| `done.<新设备>.<组员>` | 确认标签 Ta | 新设备 | 核对码 |
| `admit.<设备>.<签名者>` | 设备条目、最初是谁加的、最初加入的时间、签名 | 每台认它的组员 | 签名者是我认的组员 |
| `remove.<设备>.<签名者>` | 设备 ID、两把公钥、时间、签名 | 做移除的组员 | 同上 |

G2 再加 `host.*` / `grant.*`。

**加入（CPace-X25519-SHA512，新设备是 initiator，组员是 responder）**

- 口令：6 位数字的 ASCII。`CI` = `"uTerm device-group join v1"` ‖ 新设备 ID。`sid` 每次新的。
- `ADa` = 新设备 ID ‖ X25519 公钥 ‖ Ed25519 公钥；`ADb` = 组员的同样三项。两端只用喂进 `finish` 的那份 AD 里的钥匙。
1. 新设备点「加入」：生成 6 位数、`sid`、Ya，写 `join`，显示数字。
2. 组员看到不认识的设备的 `join`：弹输码框。输入后算 Yb、会话密钥，写 `answer`（Yb、Tb、入组包）。入组包 = 用 `deriveKey` 封的当前组员名单。组员此时**还不认**新设备，只在本机记下「等它的 Ta」（存期望的标签，App 重启后还能核对）。
3. 新设备看到 `answer`：核对 Tb。对了：解开入组包，本机记下名单（含那台组员），写 `done`（Ta），显示「已加入」。错了：这个数作废，换新数、新 `sid`、新 Ya 重写 `join`。
4. 组员看到 `done`：核对 Ta。对了：本机认新设备，写签名的 `admit`。之后别的组员读到这条 `admit` 就认它。

- **一个数只试一次**：新设备对当前 `sid` 只处理第一条 `answer`，不管对错都作废这个数。连错 3 次这次加入停止，要重新点「加入」。数 10 分钟过期。
- **组员输码后不能当场知道对错**（要等新设备回话）：输码框转成「正在核对…」，可以关掉，后台继续。错了提示「不对，「X」上换了新数」，一台组员对同一台设备 10 分钟内最多输 3 次。
- 冒充者每次只能猜一次，猜中概率百万分之一；它能做的只是写假 `answer` 让数作废（要你重输）。

**组员名单怎么算**（每台设备本机一份，每轮读名册时更新）

- 一台设备（按 Ed25519 公钥认）是组员，当且仅当：有一条我认的 `admit`，它的「最初加入时间」晚于我认的、针对这把钥匙的最新一条 `remove`。
- 「我认的」= 签名者是我当前认的组员，签名验得过。先处理 `remove`，再处理 `admit`，反复到不再变化。
- **认了就补签**：我认的每台组员，我都写一条自己签的 `admit`（保留最初的添加者和时间）。这样添加者后来被移除，离线过的设备回来也还认它加过的设备。
- 处理到一条 `remove` 时，删掉自己给那台设备签的 `admit`。本机的移除记录不过期。
- `remove` 的对象是本机：本机显示「已被移出」，停止参与，不再写任何记录。
- **移除连带**：移除一台设备时，列出「最初由它添加」的设备，默认一起移除。
- **换组**：已经和别的设备同组的设备去加入另一个组，先给自己写一条 `remove`（离开原组），再加入。

### 7.2 规格：组里的 Mac（G2）

和 §4 相比有一处收窄：**新设备不在开通结果到之前去连 Mac**。局域网上 Mac 不认识的设备一来连就会弹审批框，
没有不打扰的探测办法。所以新设备等开通结果同步过来再把那台 Mac 记下。输码之后一共三跳：新设备进组 →
组员确认它并去问各台 Mac → 开通结果到新设备。

**记录**（都由组员用 Ed25519 签名，别的设备只认「我认的组员」签的）

| account | 内容 | 谁写 |
| --- | --- | --- |
| `host.<Mac>.<签名者>` | 一台 Mac 的公开信息：ID、名字、公钥、机型、platform、时间 | 配对过它的组员 |
| `grant.<组员>.<Mac>.<签名者>` | 这台 Mac 对这台组员的开通结果：组员的 ID 与两把公钥、Mac 的公开信息、结果、原因、能否公网接入、时间；另带一个只有那台组员打得开的包（中继配置） | 去问的组员 |

- 封中继配置的钥匙：X25519(签名者的远控私钥, 对象组员的远控公钥) 经 HKDF 派生，ChaChaPoly，AAD 绑定标签、两台设备和 Mac 的 ID。
- `host` 只用来显示（「组里有哪些 Mac、本机还没通的是哪几台」），不凭它连接。

**组员怎么问**（每轮读完名册、算完组员名单之后）

- 对每台别的组员 D、每台本机配对过且此刻问得到的 Mac H：名册里没有任何我认的组员签的、针对 (D 现在的钥匙, H 现在的公钥) 的**有定论**的结果，就去问（消息 50 / 51）。D 就是 H 自己时不问。
- 不同的 Mac 并行问，同一台 Mac 上一台一台问。
- 有定论 = 已记下 / 早就认识 / 明确拒绝。连不上：不写结果，60 秒后再问。Mac 关了「允许担保」或版本太旧：写结果，6 小时后再问。
- 组员确认了一台新设备（核对过它的 Ta）之后马上跑一遍，不等下一轮。
- 清理：自己签的结果里，对象已不是组员的、Mac 已不再配对的，删掉；`host` 同理。

**新设备怎么收**

- 对象是本机、签名者是我认的组员、签名验得过的 `grant`：结果可用就解开中继包，交给 `RemoteGroupHostAccess.adopt`（不覆盖公钥不同的记录，不加回本机忘记过的 Mac）。
- 几台组员都问过同一台 Mac：可用的那条优先。
- 界面：「我的设备」里加一组「还没通的 Mac」，只列本机还不能用的（正在开通 / 要单独配对及原因）；都通了这组不显示。
- 刚进组的 10 分钟里读名册保持 2 秒一轮。

**日志**：别的设备写给本机的 `answer` / `done` / `admit` / `grant` 第一次读到时记一行「写入后 N 秒读到」，量 iCloud 钥匙串一跳的实际耗时。

### 7.3 规格：移除、被控端、组里的 Mac 互认（G3）

**移除之后请 Mac 撤销**（组员一侧）

- 我认了一条 `remove`（含连带的）之后：对每台本机配对过、问得到的 Mac，请它撤销那台设备（消息 52 / 53，带设备 ID 和它的远控公钥）。被移除的设备自己不做这件事。
- 本机记下每对（被移除的钥匙, Mac）的结果：已撤 / 它本来就不认识 = 完成；「不是同一组的」= 完成（撤不了，要到 Mac 上撤）；连不上 60 秒后再问；Mac 版本太旧 6 小时后再问。
- 同一台设备 ID 在某台 Mac 上还有没做完的撤销时，先不替这个 ID 向那台 Mac 开通（先撤旧的、再开新的）。
- 界面：「我的设备」里加一组「已移除的设备」，只在还有 Mac 没撤完时显示，每台一行（还有几台 Mac 没撤、多半在等它们上线）。

**同组撤销不拉黑**（被控端，§8）

- Mac 收到同组设备的撤销请求（消息 52）：只删信任和担保来路，不进黑名单；之后同组设备可以重新替它开通。
- Mac 主人在 Mac 上手动撤销的照旧拉黑。远控进程与 App 之间的 XPC 协议不改。

**重装过的设备**（设备 ID 相同、钥匙换了）

- 组员确认一台新设备时，如果组里已有一台设备 ID 相同、钥匙不同的组员：同时给旧的那台写 `remove`（不连带）。之后按上面的规则先在各台 Mac 上撤旧钥匙，再开通新钥匙。

**组里的 Mac 互认**（决定 2）

- 一台 Mac 是组员、并且开着被控（远程控制的「允许控制这台 Mac」）和「允许担保」时：它把组里别的组员记成自己的主控端，来路记成设备组；然后给每台组员写一条 `grant`（签名者和 Mac 是同一台），对方照 §7.2 收下。
- 公网接入：照这台 Mac 上新配对设备的默认值；能公网接入的，中继证书照担保时的做法发，封给那台组员。
- 组员被移除：这台 Mac 自己把它撤掉（不拉黑）。
- 由 App 做，远控进程不读名册。需要让远控进程知道新主控端时，XPC 只加不改。

**被移除的组员签过的开通结果**

- 本机记下每台「因为开通结果才记下的 Mac」是凭谁签的结果记的。签名者被移除后，只凭它的结果记下的 Mac 从本机的信任表里拿掉（不算「忘记」，以后别的组员再开通还能记回来）；本机自己配对的、别的组员也开通过的不动。
- 原因：被偷的组员在被移除前可以签一条假结果，让别的设备把攻击者的机器记成 Mac。

### 7.4 规格：快通道（G4，2026-11-17 user 定：局域网直连 + 中继，像远控那样挑线路）

起因：真机上 Duo 加入用了 82 秒。日志里每一趟 iCloud 钥匙串约 18 秒，加入要四趟（`join` → `answer` → `done` → `admit`），这是苹果的同步速度，轮询调不快。

做法：**名册记录除了写钥匙串，同时经一条快通道直接发给别的设备**。钥匙串照写照读、仍是唯一落盘的地方；快通道只是让同一份记录早到。上层（`RemoteDeviceGroup`、加入协议、组员名单）一行不改：它们读到的名册 = 钥匙串 ∪ 快通道收到的。

**线路**（每个对端各挑各的，谁通用谁，都通用局域网）：

1. **局域网**：Bonjour `_uterm-group._tcp`（TXT 带设备 ID），设备之间直接连 TCP。两台手机也行。
2. **中继信箱**：每台设备拿默认中继的成员密钥，以「主机」身份在中继上注册一个**信箱**（主机 ID 由设备 ID 派生，不是设备 ID 本身，另配一把只存本机的 P-256 主机钥匙）；别的设备以 `client` 身份往信箱发 `signal`，信箱在同一个 `session` 上回。中继服务端一行不改（它本来就看不懂 `box`），1.3.0 可用。记录很小，走信令就够，不用打洞：一来一回约 0.1 秒。
3. **钥匙串**：以上都不通（没有默认中继、两边都不在线、中继只有成员证书）时照旧，约 18 秒一趟。

不走远控那条已配对的链路：新设备还没和任何 Mac 配对，而最慢、最显眼的正是它加入的那四趟。也不动被控端和远控进程（XPC 协议、换包规则都不碰）。

**谁能进快通道**：只认**钥匙串名册**里有 `device.<id>` 记录的设备（设备首次启动就写了）。两端用各自的 X25519 身份钥匙和对方记录里的公钥协商密钥，协商不出来、解不开的一律不理。快通道收到的 `device` 记录只更新内容，**不给人进快通道的资格**。所以能往快通道里塞东西的，和能往钥匙串里写的是同一批设备，威胁模型不变；同一 Wi-Fi 上的陌生人弹不出加入框、烧不掉码。记录本身的校验（签名、CPace、组员名单）照旧，不因为走快通道放松。

**叠加层**（`RemoteGroupOverlayStorage`，实现 `RemoteSyncedStorage`，包着钥匙串那份）：

- `save`：写钥匙串，同时记进叠加层并广播。`delete`：删钥匙串，同时对「这个 account 当前的内容」留一个墓碑并广播。
- `loadAll`：按 account 合并。同一 account 两边内容不同，取**后到的**（钥匙串那份按「本机第一次读到这份内容」的时刻算）。钥匙串的内容变成和叠加层一样，叠加层那条就丢掉。
- 墓碑是「account + 内容摘要」：命中的记录在两边都不返回（钥匙串的删除还在路上时也先藏起来），不影响同一 account 以后的新内容。墓碑只在内存，留 10 分钟。
- 叠加层只在内存：App 重启就没了，那时钥匙串早该到了；钥匙串一直不到，等于这条记录没写出去，和今天一样。
- 上限：512 条、单条 16 KiB，超了丢最旧的非本机写的。解不出 `RemoteGroupRecord` 的不收。
- 有变化就叫醒 `RemoteDeviceGroupService` 立刻 `refresh()`，不等 2 秒的轮询。

**同步**（两条线路同一套消息，全量摘要 + 补差）：

- `sync`：我有的全部 `(account, sha256)` + 我的墓碑。对方回它有而我没有的记录，并要它没有的。
- `records`：一批原始记录（一帧不够就分批，中继一帧 64 KiB）。`tombstones`：一批墓碑。
- 连上时、本机叠加层或钥匙串有变化时（50 毫秒合并一次）、此外每 30 秒各发一次 `sync`。
- 转手：从 A 收到的也发给 B（合并后的名册就是要同步的全集）。A、B 互相够不着、都够得着 C 时照样快。
- 密封：局域网连接上两端各出 32 字节随机数，会话密钥 = HKDF(X25519 共享秘密, 两个随机数)，每帧 ChaChaPoly；中继信箱的 `box` 用 HKDF(X25519 共享秘密, salt `uterm-group-sync-v1`)，AAD 绑 `session`、方向、两端设备 ID，带发送时间和随机数防重放。

**什么时候开着**：Mac 上 App 开着就听、就找、信箱就注册着。iOS 只在前台（退后台全部收掉）。本机没有远控身份时不开。测试宿主里不开（和正式版共用钥匙串与局域网）。

**日志**：`设备组：经局域网 / 中继收到「…」的 <kind>，写入后 N 秒`，和现有的钥匙串那条并排，真机上能直接比。

**分两期**：G4a 叠加层 + 同步 + 局域网；G4b 中继信箱。

## 8. 被控端要改的

- **被同组设备撤销的，不进黑名单**。现在 `RemoteIdentityStore.revoke` 不分来路，一律把设备加进 blocked，之后的担保全被拒（「这台设备在这台 Mac 上被撤销过」）。改成：同组设备请求的撤销只删信任，不拉黑；Mac 主人在 Mac 上手动撤销的仍然拉黑。不拉黑之后，被撤设备担保过的设备能把它担保回来，所以同组撤销同时**连带撤掉一层层由它担保的设备（发请求的那台除外，也都不拉黑）**，见 §15「同组撤销连带」。
- **重装过的设备重新加入**：设备 ID 相同、公钥变了，现在的担保规则会拒绝。改成组员先撤旧的、再担保新的（两条现有消息），不新增消息。
- 消息 50–53、能力位、XPC 协议都不变。

## 9. 对比

| | 现在 | 设备组 |
| --- | --- | --- |
| 三台设备全部互通要核对几次 | 6 次（每个方向一次） | 2 次（第二、第三台各加入一次） |
| 每次核对你的操作 | 发起、输码、另一端点「允许」 | 点「加入」、另一端输码 |
| 第三台加入后，前两台要做什么 | 各自再确认 | 不用做 |
| 一台设备的状态 | 确认状态 × 担保者 × 每台 Mac 进度 | 在组里 / 不在 |
| 设备丢了 | 报告丢失；可取消，但 Mac 不恢复 | 移除；找回后重新加入，Mac 自动恢复 |
| 被控端协议 | 消息 50–53 | 不变，改一条撤销规则 |

## 10. 已定（2026-11-16，user 按推荐定）

1. **核对方式**：先做 C 的探针，过了用 C，不过用 A。
2. **组里的 Mac 互相控制**：Mac 进组后自动认组员当主控端。
3. **撤销不拉黑**：同组设备请求的撤销不进黑名单，重新加入后自动开通。
4. **移除时连带**：默认一起移除它加进来的设备，可取消勾选。

## 11. 分期

- **G0 探针**：CPace 两点验证。已做，60651a59。
- **G1a 组的核心**：签名钥匙、名册记录、本机组员表、加入协议两端、移除与连带。只加新文件和单元测试，不接界面，旧的一对一确认不动。
- **G1b 接上界面**：App 级服务换成设备组、两端「我的设备」和弹窗重做，删掉一对一确认那一层和它的测试。
- **G2 Mac 目录与自动开通**：`host` / `grant` 记录、并行担保、新设备直接连、「我的 Mac」行上的状态。
- **G3 被控端与收尾**：移除时请 Mac 撤销、撤销不拉黑、重装设备、Mac 组员互认。
- **G4 快通道**（2026-11-17 user 定要做）：名册记录经局域网直连或中继信箱直接送到，钥匙串垫底。规格见 §7.4。二维码不做。

现在的实现还没发版，只有三台测试设备装过，不需要迁移：新名册换一个钥匙串 service，旧记录启动时清掉。

## 分支里的问题（`claude/sibling-confirm-popup`，未合 main）

今天改的「新设备先点『允许』」有一个漏洞，写在这里备查：

- 钥匙串圈里的冒充者可以在名册里登记一台假设备，起一个和真设备一样的名字，向新设备发确认请求。
- 新设备弹窗：「「iPhone Duo」想替这台设备开通远程控制」，带「允许」。
- 你点了「允许」，冒充者自己写一条「核对通过」，新设备就把它记成担保者。全程没有人在任何地方输过码。
- 后果：冒充者可以让新设备列出假的「Mac」（你可能往它的终端里打字），拿不到真 Mac 的控制权。
- 改之前（644dd274，等「核对通过」才出「允许」）同样能被这样骗，只是弹窗会在你没输码时就显示「已核对通过」，更容易起疑。main 上比对两个数的版本没有这个问题。
- 前提是攻击者已经在你的 iCloud 钥匙串圈里。设备组的方案 C 从根上去掉这一环。

建议这条分支不合进 main，等设备组做完直接替换。

## 12. G1a 落地

2026-11-16，分支 `claude/sibling-confirm-popup`。只加了新文件，没接界面，旧的一对一确认（`RemoteSibling*`）一行没动。

### 文件

- `uTerm/Core/Remote/RemoteGroupRoster.swift`：设备条目、六种记录、签名的规范字节、信封编解码、快照、名册（service `com.uozi.uTerm.remote.group`）。
- `uTerm/Core/Remote/RemoteGroupJoinCrypto.swift`：6 位数与 sid、CPace 参数、入组包与 `done` 条目的封包、组员要存的期望 Ta。
- `uTerm/Core/Remote/RemoteGroupMembership.swift`：组员名单算法（纯函数）。
- `uTerm/Core/Remote/RemoteGroupLocalStore.swift`：只存本机的状态与 Ed25519 签名私钥；本机条目的取法（不在后台生成身份）。
- `uTerm/Features/Remote/RemoteDeviceGroup.swift`、`RemoteDeviceGroup+Join.swift`：`@MainActor @Observable` 模型，两端共用。
- 测试：`uTermTests/Core/Remote/RemoteGroupRosterTests.swift`（16 个）、`RemoteDeviceGroupTests.swift`（28 个）。

### 名册记录（iCloud 钥匙串 `com.uozi.uTerm.remote.group`）

信封 `{v:1, record:"device"|"join"|"answer"|"done"|"admit"|"remove", <同名字段>:…}`，日期按 1970 起的秒数。解不开、版本不对、长度不对（两把公钥各 32、sid 16、份额 32、确认标签 64、签名 64）、签名与它自称的签名者对不上的，解码时就丢掉。`loadAll` 拿不到 account，所以 account 只用来写和删，读的时候不信它。

| account | 内容 |
| --- | --- |
| `device.<id>` | `RemoteGroupDevice`：id、name、model、platform、`publicKey`（X25519）、`signingKey`（Ed25519）、updatedAt |
| `join.<新设备>` | 新设备条目、sid、Ya、createdAt |
| `answer.<新设备>.<组员>` | candidate、sid、组员条目、Yb、Tb、入组包、createdAt |
| `done.<新设备>.<组员>` | candidate、member、sid、Ta、封好的新设备条目、createdAt |
| `admit.<设备>.<签名者>` | 设备条目、admission（admitterID、admitterKey、admittedAt）、signer、signerKey、**signedAt**、signature |
| `remove.<设备>.<签名者>` | deviceID、publicKey、signingKey、removedAt、signer、signerKey、signature |

**要比先后、要签名的时间**（admittedAt、removedAt、signedAt）是 `RemoteGroupTime`：毫秒整数，JSON 里就是一个整数。`Date` 经 JSON 来回一趟可能差一个 ulp，「移除时间 ≥ 加入时间」会随机翻转。

**签名**：Ed25519（CryptoKit `Curve25519.Signing`）。签的不是 JSON，是 `RemoteGroupCanonical`：先放用途标签，之后每个字段带 LEB128 长度前缀依次拼（`CPace.prependLength`）；可选字符串先放一个字节 0/1 再放内容；UUID 16 字节；时间大端 8 字节。签名覆盖除签名之外的每个字段。

- `admit` 标签 `"uTerm device-group admit v1"`，顺序：设备（id、name、model、platform、X25519、Ed25519、updatedAt 取整到毫秒）、admitterID、admitterKey、admittedAt、signer、signerKey、signedAt。造记录时先把 updatedAt 取整到毫秒再签，不然经 JSON 之后取整可能落到相邻一毫秒。
- `remove` 标签 `"uTerm device-group remove v1"`，顺序：deviceID、X25519、Ed25519、removedAt、signer、signerKey。

### 本机存储（`RemoteSecretStorage`，和远控身份同一个 service）

- `groupSigningKey`：Ed25519 私钥原始 32 字节。只在前台（`createsIdentity: true`）生成；后台用 `existingSigningKey()`，没有就不建模型。
- `groupState`：`RemoteGroupLocalState` 的 JSON：`members`（条目 + admission）、`removals`（每把 Ed25519 钥匙只留最晚一条，不过期）、`selfAdmission`（本机怎么进的组；只有自己一台时为 nil）、`selfRemoved`、`pendingJoins`（组员一侧等 Ta 的：新设备条目、sid、期望的 Ta、开 `done` 条目的钥匙、admittedAt、submittedAt）、`submissions`（每台新设备的输码时间）。
- 读 `groupState` 时钥匙串报错就抛出，不当成空的：当成空的再写回去会把名单清掉。格式坏了才当空的。

### 加入

CPace 参数照 §7.1：口令是 6 位数字的 ASCII（`normalizedCode` 只留 ASCII 数字，全角不算），CI = `"uTerm device-group join v1"` ‖ 新设备 ID 16 字节，AD = 设备 ID ‖ X25519 ‖ Ed25519（80 字节）。会话密钥派生：入组包 `deriveKey(info: "uTerm device-group admission v1")`，`done` 条目 `deriveKey(info: "uTerm device-group done v1")`。两者都是 ChaChaPoly，附加数据 = 规范编码的（标签、sid、新设备 ID、组员 ID）。

入组包 `RemoteGroupAdmissionPackage`：`member`（组员自己的条目与它当初的 admission）、`others`（它认的其它组员）、`removals`（它的移除记录）、`admission`（给新设备的：添加者 = 这台组员、加入时间）。

新设备一侧（`joinState`）：

- `startJoin()`：生成数、sid、Ya，写 `join`，状态 `.showingCode(数, attemptsLeft: 3)`。本机所在的组不动；核对通过时才离开原组（见「G1a 补充」第 2 条）。
- 每轮：只看 sid 与当前一致的 `answer`，按 createdAt、再按组员 ID 取第一条，只处理这一条。Tb 对、入组包打得开、包里的组员条目的 ID 与两把钥匙就是喂进 `finish` 的那份、包里给本机的添加者就是这台组员，才算通过：本机名单换成包里的，写 `done`，撤下 `join`，状态 `.joined`。否则这个数作废，换数、换 sid 重写 `join`；作废第 3 次就停（`.failed`），撤下 `join`。数从生成起 10 分钟过期，过期就停。
- 名册里本机的 `join` 和本机记的不一样（没同步上、被删、被改）就重写。`done` 在看到那台组员签的、针对本机的 `admit` 之前也会被重写，最多 24 小时。
- 这一轮的数只在内存。App 重开后旧数作废，名册里本机的 `join` 被清掉，要重新点「加入」。

组员一侧（`joinRequests`，状态 `.waitingForCode(attemptsLeft:)` / `.verifying` / `.wrongCode(attemptsLeft:)` / `.limitReached` / `.admitted`）：

- 列出名册里的 `join`：不是本机、本机还不认这把钥匙、10 分钟内的、没被你拒绝（按 sid）的。本机自己在加入时、被移出时不列。
- `submitCode(_:for:)`：先记一次输码（份额不合法也算），10 分钟内同一台新设备超过 3 次就拒绝。算 Yb 与会话密钥、入组包、期望的 Ta、`done` 条目钥匙，**先存待核对、再写 `answer`**。一直只有自己一台的设备第一次替别人输码时，`selfAdmission` 记成（自己, 自己, 现在）。
- 每轮：对每条待核对，找 sid 相同、Ta 与存下的期望值相同（常数时间比较）的 `done`，条目打得开、ID 与两把钥匙等于 `join` 里那份，才认它；没认之前不写任何 `admit`。假的 `done` 只是忽略、继续等（Ta 是 64 字节 MAC，猜不出来）。别的组员先认了它就不等了。待核对留 24 小时，但「正在核对」只显示 10 分钟。
- 状态：有当前 sid 的待核对 → `.verifying`；次数用完 → `.limitReached`；10 分钟内输过、但都不是当前 sid → `.wrongCode`；否则 `.waitingForCode`。`dismissJoin` 隐藏这一轮、丢掉本机的待核对、删掉本机的 `answer`。

### 组员名单（`RemoteGroupMembership.resolve`）

- 签名者认不认（`Signers`）：签名者的 ID 与 Ed25519 钥匙都对得上本机认的某台组员（或本机自己），**并且记录的时间（admit 的 signedAt、remove 的 removedAt）不早于这台签名者进组的时间**。
- 每一遍：先处理 `remove`（不含针对本机的），按 removedAt 从早到晚一条条来，每条都按此刻的组员判断签名者，应用了就马上去掉被移除的组员；再处理 `admit`，按这一阶段开始时的组员判断签名者，加入时间晚于本机记的最晚移除才认，同一把钥匙有几条时取加入时间最晚的。反复到不再变化。
- 移除生效的条件是「最晚的移除时间 ≥ 组员的加入时间」。
- 本机被移出：本机认的组员（不是本机自己）签的、针对本机钥匙、时间不早于本机这次加入的 `remove`。被移出后 `refresh()` 什么都不写（不登记、不补签、不回请求），`isSelfRemoved` 为真，直到 `startJoin()` 或 `leave()`。
- 补签（`publishAdmits`）：本机认的每台组员都有一条本机签的、内容相同、signedAt 不早于本机进组时间的 `admit`，没有就签；本机签的、不再认的删掉。
- `remove(_ ids:)`：按设备 ID 移除本机认的组员，removedAt = max(现在, 它的加入时间, 本机的进组时间)，本机马上生效并删掉自己给它签的 `admit`。`devicesAdmitted(by:)` 返回由那台设备加进来的组员，一层层算到底、不经过本机（见「G1a 补充」第 1 条）。`leave()`：在组里就签离开记录，删掉本机签的所有 `admit`，回到只有自己一台。
- 组员输码时定的加入时间 = max(现在, 本机记的对这把钥匙的最晚移除 + 1 毫秒)。

### 给界面的输出

`members`（本机在第一行，`isLocal`、`admittedByName`）、`isInGroup`、`otherDevices`（名册里的条目减去本机认的钥匙和本机 ID；只显示，不可信）、`isSelfRemoved`、`joinState`、`joinRequests`、`isAwaitingOthers`（有加入在进行，轮询该改快）、`storageError`。操作：`refresh()`、`startJoin()`、`cancelJoin()`、`submitCode(_:for:)`、`dismissJoin(_:)`、`remove(_:)`、`devicesAdmitted(by:)`、`leave()`。建模型用 `RemoteDeviceGroup.live(createsIdentity:)`；`createsIdentity: false` 时身份、设备 ID、签名私钥缺一样就返回 nil。`pollInterval` 2 秒。

### 与 §7.1 不同、或 §7.1 没说的地方

- **`admit` 多一个 signedAt，签名者只在进组之后签的才算（`remove` 用 removedAt 同样判）。** §7.1 只要求签名者是当前组员。不加这一条，换过组的设备在旧组签的 `admit`（离开时删了，钥匙串圈里的人能读到再写回来）会被新组认，把旧组的设备、包括旧组已经移除的设备带进新组。离开时删掉自己签的所有 `admit` 也是为了这个。
- **removedAt 取 max(现在, 被移除者的加入时间, 自己的进组时间)；重新加入的加入时间取「本机记的移除 + 1 毫秒」以后。** §7.1 只说按时间比。被偷的组员可以把它加的设备的加入时间写到将来，按「现在」移除就移不掉；钟不准时重新加入也可能被旧移除挡住。
- **`remove` 按时间先后、每条按此刻的组员判断签名者。** §7.1 说「先处理 remove，再处理 admit，反复到不再变化」，没说同一遍里一台签名者被移除后它的其它 `remove` 算不算。这样定：离线很久的设备同时读到「C 被移除」和 C 移除之后签的记录，也不认后者。
- **`done` 里多封了一份新设备的条目；入组包里放的是组员自己那份条目。** §7.1 的 AD 只有 ID 与两把钥匙，名字、机型在名册里谁都能改（中间人改了也不影响核对）。现在记下的名字经核对码认证。为此组员要存一把开条目的钥匙。
- **入组包里还带着组员的移除记录、组员自己当初的 admission、给新设备的 admission。** 钥匙串圈里的人能删掉名册里的 `remove`，新设备只看名册就可能被残留的旧 `admit` 骗回已移除的设备；新设备要知道自己的加入时间，才能判断后来的 `remove` 是不是冲着这一次加入。
- **期望的 Ta**：`CPaceKeys` 只给 `verifyPeerConfirmation`、不给期望值，`CPace.swift` 按约定没改。组员用 `CPace.macKey` / `CPace.confirmationTag` 按 draft §10.4 重算一遍，再用 `verifyPeerConfirmation` 核过才存。以后可以给 `CPaceKeys` 加一个导出期望标签的接口，省掉这段重算。
- **新设备的这一轮只在内存**，App 重开就换数（§7.1 只要求组员一侧能跨重启）。
- **数过期就停，不自动换数。** 同一轮里有几条 `answer` 时取 createdAt 最早的；冒充者可以把时间写早来抢先，结果也只是这个数作废。
- **待核对留 24 小时**（§7.1 只说组员 10 分钟内最多输 3 次）：Ta 猜不出来，留久一点只为对方离线时还能接上；「正在核对」只显示 10 分钟。
- 第一台设备（一直只有自己）第一次替别人输码时，自己的 admission 记成（自己, 自己, 那一刻）。
- 本机自己在加入时，不显示别人的加入请求。
- 被移出的设备 `leave()` 不签离开记录，但会删掉自己签过的 `admit`（这是你点的操作，不是后台写）。
- 名单按 Ed25519 钥匙认人，`remove(_:)` 按设备 ID 选人（同一个 ID 有几把钥匙时一起移除）。
- 启动时清掉旧名册 `com.uozi.uTerm.remote.devices` 里本机写过的记录，留给 G1b 接界面时做。

### 方案本身的风险（G1a 没有解决）

- **移除连带可以被躲过**：已在补充里堵上（加入信息带最初添加者的签名、连带一层层算到底），见下面「G1a 补充」。
- **被偷的组员把移除记录的时间写早**：在线的设备已经不认它，不受影响；但离线很久才回来的设备会同时读到它被移除和这些写早了的移除，按时间排在前面，照样生效。后果是那台离线设备上少了几台组员（要重新加），拿不到任何控制权。
- **只靠各台设备的钟排先后**：已经尽量取 max 防住，但组员还没读到某条移除时就替那台设备重新加入，而做移除的设备钟快了很多，重新加入在那几台设备上会被旧移除挡住，要再加一次。
- **新设备先于组员认对方**：仍然如此（协议决定的），但界面现在看得出来：`awaitingAcknowledgement`，见「G1a 补充」。`done` 一直到不了时新设备一直显示在等。
- **拒绝服务**：钥匙串圈里的人能删、能改名册里任何一条：抢先回假 `answer` 让数作废（连续 3 次就停）、覆盖 `join`、删 `admit` / `remove` / `done`。方案接受这一条；本机的组员与移除记录删不掉。
- **按设备 ID 起的 account**：同一个 ID、换了钥匙（重装后 ID 没变）时，新旧两把钥匙的 `admit` 落在同一个 account 上互相覆盖。G3 处理重装设备时要一起看。
- **换组时先离开**：已改成核对通过时才离开，见「G1a 补充」。

### 测试

`RemoteGroupRosterTests`：service 与 account 名；六种记录来回编解码；长度不对、版本不对、garbage 都丢；`admit` / `remove` 的签名覆盖每个字段（逐个改一遍）；两种记录的签名互不通用；规范编码无歧义（换切法、nil 与空串）；非整毫秒的登记时间签完经 JSON 仍验得过；`RemoteGroupTime` 精确与边界；码的格式与归一化；同码才对得上、CI 绑新设备；组员存的 Ta 就是新设备会回的；入组包绑 sid、新设备、组员、用途；名单与记录顺序无关；签名者进组前签的不算；本机状态读不出时报错。

`RemoteDeviceGroupTests`：
- 正常：两台加入，组员只在 `done` 之后签 `admit`；第三台经任一组员加入、第四台经第三台加入，其它组员什么都不做也收敛；添加者被移除后离线的组员靠补签仍认它加的设备；被移除的设备用新数重新加入；组员输码后重启仍能核对；连带列表；换组时旧组员不跟过去，冒充者写回旧补签也不行。
- 攻击：不认识的钥匙、冒用组员 ID、改名字 / 钥匙 / 时间、挪签名，都不改名单；被移除的组员之后签的不认；假 `device` 条目不改名单；被偷的组员把加入时间写到将来也移得掉；假 `answer` 让数作废、3 次后停；假 `join` 被输了真数也进不来、打不开入组包、假 `done` 无用；中继改 `join` 换钥匙、换份额，改 `answer` 换组员钥匙，都没人被认；旧 `answer`、旧 `done` 重放（原样或改 sid）都不认；一个数只试一次，先到的假 `answer` 作废之后正确的也不处理；两台组员都输对只用先到的、另一台弹窗自动关；输错显示「换了新数」、10 分钟 3 次的限额；格式不对的码不提交不计次。
- 其它：被移出后不再写任何记录、它之后签的不认（离线设备同时读到也不认）；数过期；取消与重启撤下 `join`；拒绝只隐藏这一轮；后台建模型不生成身份和签名私钥；本机存储读不出时不动名册。
- 用变异核过关键测试会失败：去掉签名者的进组时间检查、移除时间不取被移除者的加入时间、新设备验多条 `answer`，各自对应的测试都红。

### G1a 补充（2026-11-16，三处改动）

**1. 「最初是谁加的」可以验证**

- `RemoteGroupAdmission` 多一个 `signature`：添加者用自己的 Ed25519 私钥签，标签 `"uTerm device-group original-admission v1"`，内容依次是被加设备的 ID、X25519、Ed25519、admitterID、admitterKey、admittedAt（同样是带长度前缀的规范编码）。添加者在输码时就签好，存进待核对、封进入组包；之后谁补签都原样带着。`admit` 的签名内容里也加上了这个签名。
- 一直只有自己一台的设备第一次替别人输码时，自己的加入信息是（自己, 自己, 那一刻），也由自己签。它只出现在入组包里：**名册里自己加自己的 `admit` 解码时就丢掉**，组里的第一台也不再被补签（组里每台设备进组时都从入组包里认了它，从不需要靠名册认它）。
- 名册里的 `admit` 要被认，除了 G1a 的规则，还要：
  - 最初添加者的签名在 admitterKey 下验得过（解码时验）；
  - 添加者不是被加的设备自己（解码时验）；
  - 添加者是本机认得的设备：本机、本机认的组员，或者本机确认当过组员、后来被移除的设备，ID 与钥匙都对得上（`Signers.knowsAdmitter`）。从没见过的不认，下一遍再看。
- 「确认当过组员的已移除设备」：移除时它在本机名单里；或者 `remove` 记录里带着它的加入信息（`remove` 新增可选字段 `admission`，进签名），签名对得上，添加者本机认得，而且不是自己加自己。这样，离线时有一台设备加入、加了别的设备、又被移除，回来的组员照样认它加的设备。本机的移除记录（`RemoteGroupRemoval`）为此多存了 X25519 公钥和这份加入信息，入组包里的移除记录也带着。
- **移除连带改成一层层算到底**（`devicesAdmitted(by:)`）：这台设备加的，再加上它们加的，依此类推，链条也经过带着加入信息的已移除设备，但不经过本机（本机加的设备不连带）。
- 为什么这样就够：被偷的组员只能把它加的设备记到「它手里有私钥的、本机认得的设备」名下。这样的设备要么是它自己，要么是它先加进来的设备，要么是它先加进来、再移除的设备（「现造一把钥匙、记成自己加的、马上移除，再由那把钥匙去加」），三种都落在它自己的连带链条上。如果只算直接加的，「先加一台自己的设备，再由那台去加」就躲过去了，所以必须算到底。
- 补签时把已有组员改记到别人名下：补签的签名是自己的，但最初添加者的签名还是原来那份，改了添加者就对不上，整条丢掉。已经认了的组员本机记的加入信息不会变，照样报真正的添加者。
- 代价：移除组里的第一台时，连带会列出它加的所有设备。这是对的（第一台丢了，它加的设备都可能是小偷加的），界面上可以取消勾选。

**2. 换组改成核对通过时才离开**

- `startJoin()` 不动本机所在的组：只生成数、写 `join`。取消、输错 3 次、过期，本机都还在原组里，原组照常认它、它也照常补签。
- 核对通过、收下新组的入组包时（`adopt`）才签离开记录、删掉本机签过的所有 `admit`，再换成新组的名单。被移出过的设备不签离开记录。被移出的设备点了「加入」后，`refresh()` 只推进这一次加入，别的照旧不写。
- **离开记录（自己签的 `remove`）只对它带着的那一次加入生效**：本机名单里有这台设备、而且本机记的加入信息与记录里带的完全相同才算，否则这条什么都不做，也不记成移除。原因：离开是在新组的组员已经输码、给了加入时间之后才签的，时间晚于新组给的加入时间，只按时间比，新组的设备也会把它移除（这条测试在改动中真的红过）。别人签的移除仍然只按时间比：不同设备可能按不同的 `admit` 认了同一台，按加入信息匹配的话，被偷的组员能让一次移除只在部分设备上生效。

**3. 「已加入、还没人认」看得见**

- 新增 `awaitingAcknowledgement: RemoteGroupDevice?`：新设备核对通过后就是那台输码的组员（存在本机状态 `acknowledgementFrom` 里，App 重启后还在）；看到本机认的某台组员签的、认本机**这一次**加入的 `admit`（加入信息与本机记的相同，签名者按 `Signers` 认）就清掉。`isAwaitingOthers` 也算上它。
- `done` 的收起条件同样改成「有本机认的组员签了认本机这次加入的 admit」，不再只认输码的那一台。

**新增测试**（`RemoteGroupRosterTests` 19 个、`RemoteDeviceGroupTests` 33 个）：加入信息的签名绑设备、添加者、时间、两把钥匙；名册丢掉添加者签名对不上的、自己加自己的 `admit`；从没见过的添加者不认，自称第一台的移除记录不让它变成认得的；补签改记到别人名下不被采信、仍报真正的添加者；被偷的组员经自己加的设备、经「加了再移除」的钥匙去加设备，都在它的连带里，移除后各台收敛；离线时添加者加入、加设备、被移除，回来照样认；连带算到底且不经过本机；第一台不补签；点「加入」后取消、输错、过期都不离开原组；换组成功后原组不再认它、旧组的设备借旧补签也进不了新组；等回执的显示、重启后保留、假 `admit` 清不掉。用变异核过：去掉添加者认得检查、去掉加入信息的签名检查、连带只算一层、离开记录不限加入、不用移除记录带的加入信息，各自对应的测试都红。

**仍然不严的地方**

- 离开记录被钥匙串圈里的人删掉时，原组里还没处理它的设备会一直把这台设备当组员，进而相信它在新组里签的记录，把新组的设备也认进来。两组都是你自己的设备，冒充者拿不到控制权；G1a 删除其它记录时也有同样的问题。
- 被偷的组员把移除记录的时间写早、钟不准时的先后问题，同 G1a 的说明，没有变。
- 连带只能连到小偷**经组员身份**加进来的设备；它移除之后什么都加不进来，这一条依旧成立。


## 13. G1b 落地

2026-11-16，分支 `claude/sibling-confirm-popup`。设备组接上了两端界面，一对一确认那一层删掉了。组员替彼此向 Mac 开通（G2）还没做：G1b 之后**暂时没有任何担保**。

### 文件

新增：

- `uTerm/Features/Remote/RemoteDeviceGroupService.swift`：App 级单例（替代 `RemoteSiblingService`）。
- `uTerm/Features/Remote/RemoteDeviceGroupCopy.swift`：两端共用的文案、`RemoteGroupRemovalPlan`（移除连带的勾选）、`RemoteDeviceGroup.listedOtherDevices`。
- `uTerm/Features/Remote/RemoteDeviceGroupPrompt.swift`：Mac 的输码面板（mac-only，替代 `RemoteSiblingPrompt`）。
- `uTerm/Features/Remote/RemoteGroupHostAccess.swift`：问 Mac 的那一层，从 `RemoteSiblingDevices+Grants.swift` 搬来并改名（`RemoteGroupHostAccess` / `RemoteGroupVouchTarget` / `RemoteGroupAdoption` / 明文的 `RemoteGroupGrant`，设备参数换成 `RemoteGroupDevice`），连同 `RemoteMacDirectory` 的实现。G2 用，现在没有调用方。
- `uTerm/Core/Remote/RemoteLegacyDevices.swift`：启动时清旧数据。
- `uTermMobile/Screens/Remote/RemoteGroupJoinHandler.swift`：iOS 根视图上的输码单子（替代 `RemoteSiblingConfirmHandler`）。

重写：`uTerm/Features/Settings/Views/RemoteMyDevicesGroup.swift`（Mac）、`uTermMobile/Screens/Remote/RemoteMyDevicesScreen.swift`（iOS）。

删除：`RemoteSiblingDevices.swift`、`RemoteSiblingDevices+Grants.swift`、`RemoteSiblingService.swift`、`RemoteSiblingPrompt.swift`、`Core/Remote/RemoteSiblingRoster.swift`、`RemoteSiblingConfirmHandler.swift`，测试 `RemoteSiblingTests`、`RemoteSiblingGrantTests`、`RemoteSiblingServiceTests`。

改动：`RemoteMacDirectory.adopt` 收 `RemoteGroupGrant`；`RemoteMacClient.vouch(for:)` 收 `RemoteGroupDevice`；`RemoteSecretStorage` 加 `delete(_:)`、`RemoteSyncedStorage` 加 `deleteAll()`（清旧数据用，各实现都补上）；pbxproj 的 iOS 排除表里 `RemoteSiblingPrompt.swift` 换成 `RemoteDeviceGroupPrompt.swift`。远控进程的编译清单不涉及这些文件，没动。被控端（`RemoteVouch.swift` 的消息 50–53 类型、`RemoteHostServer` / `RemoteHostConnection`）原样保留，名字也不改。

### 服务

- 全 App 一个 `RemoteDeviceGroup`。Mac 在 `bootstrapAppServices` 里 `start(hosts:)`，一直跑；iOS 跟着前后台 `start` / `stop`。测试宿主里不跑。
- 2 秒一轮的条件：有页面开着（`keepActive()`）、本机在显示核对码、有别的设备的加入请求（`.admitted` 不算）、`isAwaitingOthers`；否则 10 秒。
- 后台用 `live(createsIdentity: false)`：没有远控身份或设备 ID 就不建模型、什么都不生成；**两样都有、只缺签名私钥时生成签名私钥**（G1a 是返回 nil）。不然用着远程控制、但没打开过「我的设备」的设备永远不登记、也弹不出加入请求。打开页面（`ensureModel()`）照旧全部生成。本机登记现在由每轮 `refresh()` 做，启动时不再单独登记。
- 弹窗问哪个：`pendingRequest` = 名单顺序的第一个，跳过 `.admitted`、跳过你点过「关闭」且状态没变的（`hiddenRequests` 记关闭时的状态；输错后状态变成 `.wrongCode`，再弹）。`.admitted` 的请求每轮由服务 `dismissJoin` 收掉：弹窗在成功时自己关，留着的话轮询一直是快的。
- `hosts`（`RemoteMacDirectory`）只是拿着，给 G2。

### 界面（§6）

| 状态 | Mac（`RemoteMyDevicesGroup`） | iOS（`RemoteMyDevicesScreen`） |
| --- | --- | --- |
| 还没进组 | 本机一行带「加入」，下面列 `listedOtherDevices`；没有就提示去另一台设备上打开 uTerm；footer 是一句说明 + 怎么加入 | 本机一行 +「加入」行，「你的其它设备」一组 |
| 显示核对码 | 本机行下面大字 6 位数、「取消」；作废过说「换成了这个新数，还能再试 N 次」 | 同，一组里显示 |
| 加入失败 | 原因 +「好」 | 同 |
| 已进组 | 组员名单（名字、机型、「这台设备」、「由「X」添加」），每行「⋯」里一个操作：别的设备「移除…」、本机「离开…」；`awaitingAcknowledgement` 时顶上一行「还在等「X」确认」；另一组「不在组里的设备」，footer 说去那台设备上点「加入」 | 同 |
| 移除确认 | sheet `RemoteGroupRemoveSheet`：一句说明，连带设备（`devicesAdmitted(by:)`）默认勾上、可取消 | sheet，`MCheck` 勾选 |
| 离开确认 | alert | confirmationDialog |
| 被移出 | 一行警示 + 本机行带「加入」；原来组里的设备也列出来 | 同 |

组员一侧的输码（Mac `RemoteDeviceGroupPrompt`，浮动面板、没开窗口也能弹；iOS `RemoteGroupJoinHandler`，不能下滑关）：

- `.waitingForCode`：「「X」想加入你的设备」、输入框、「拒绝」/「核对」（iOS 输满 6 位自动核对）。
- `.verifying`：「正在核对…」、转圈、「关闭」（后台继续）。
- `.wrongCode`：红字「不对，「X」上已经换了新数。还能再试 N 次」，输入框清空。
- `.limitReached`：说次数用完，「关闭」。
- 核对通过或请求没了：自己关。

### 旧数据

`RemoteLegacyDevices.retireLocalLeftovers()`（两端 `App.init`，原来登记本机的位置）：后台线程上删掉 iCloud 钥匙串 service `com.uozi.uTerm.remote.devices` 下的每一条（删除会同步到别的设备；旧版没发布过），以及本机 `siblingApprovals` / `siblingCommits` / `siblingVouchers` / `siblingRevocations`。没有就什么都不做，每次启动都调。测试宿主里直接返回。

### 与方案、与 brief 不同的地方

- §6 写「名单下方列出还没进组的设备，带『添加』」：没做「添加」。核对码只在新设备上生成，组员这边没什么可点的，只写一句「在那台设备上点『加入』」。弹窗被关掉之后，状态变了会再弹。
- 「加入后，你在任何一台设备上配对过的 Mac，这台设备都能用」这句说明是 G2 之后才成立的，G1b 就先用上了。
- 组员名单每行的操作放进「⋯」菜单（同一页「已配对的设备」的写法），不是直接的按钮。
- 被移出时，`otherDevices` 不列本机还记着的原组员（它们的钥匙还在本机名单里），界面上用 `listedOtherDevices` 补上。

### 核心里不顺手的地方（没改）

- 组员输错一次以后，那条待核对要留 24 小时，这期间 `isAwaitingOthers` 一直为真，服务就一直 2 秒一轮。
- `.admitted` 的请求要有人调 `dismissJoin` 才消失，现在是服务每轮代劳。
- 被移出后 `members` 还是旧名单（见上一节）。

### 测试

- `RemoteDeviceGroupServiceTests`（6）：后台不生成身份、打开页面才生成且只建一次；弹窗显示请求，关掉后不弹，输错后再弹，核对通过后不弹也不留；拒绝；`pending` 的取舍；显示核对码、有人想加入、等回执时快，结束后慢；有人在看时快。
- `RemoteDeviceGroupCopyTests`（6）：连带默认全勾、可取消、顺序；核对码说明换数时不同；名单副标题；输码弹窗各状态的输入 / 警示 / 文案；被移出后照样列出原组员；旧数据只删该删的、可以重复跑。
- `RemoteGroupHostAccessTests`（3，从 `RemoteSiblingGrantTests` 搬来）：`RemoteGroupGrant` 的 usable / final；目录收下 Mac 的规则（新增、早就认识、公钥不同不覆盖、忘记过的不加回）；真服务端上 iPhone 替 iPad 担保、iPad 的目录收下、不经审批连上。
- `RemoteDeviceGroupTests`：「后台不生成」拆成两条：没身份时什么都不生成；有身份时后台补签名私钥并登记、打开页面用同一把。
- `RemoteVouchTests`、`RemoteHostAgentTests`、`RemoteGroupRosterTests` 换成新类型。
- `SettingsPageSnapshotTests.testRenderMyDevicesGroup`：还没进组、显示核对码、三台的组（带等回执和不在组里的设备）、移除确认、被移出、输码面板三个状态，浅色 / 深色各一张。

## 14. G2 落地

2026-11-16，分支 `claude/sibling-confirm-popup`。组员替彼此向 Mac 开通接上了。移除时请 Mac 撤销、撤销不拉黑、重装设备、Mac 组员互认仍是 G3。

### 文件

- `uTerm/Core/Remote/RemoteGroupHostRecords.swift`（新）：`RemoteGroupHostInfo`、`host` 记录 `RemoteGroupHost`、`grant` 记录 `RemoteGroupHostGrant`、中继包 `RemoteGroupRelaySeal`。`RemoteGroupRoster.swift` 的信封、解码、快照加了这两种。
- `uTerm/Features/Remote/RemoteDeviceGroup+Hosts.swift`（新）：发 `host`、清理、收、问，以及量一跳耗时的日志；`RemoteGroupVouchTasks`（正在问的请求，模型释放时取消）。
- `RemoteDeviceGroup.swift`：模型多了 `identityKey`（本机远控私钥，可为 nil）、`hosts`（弱引用）、`pendingHosts`、`isOpeningHosts`；`refresh()` 最后一步调 `syncHosts`，被移出的三个分支调 `haltHostWork()`。`RemoteGroupDevice.local` 多返回远控私钥，`make` 交给模型（后台照旧不生成身份）。
- `RemoteGroupHostAccess.swift`：协议加 `pairedHosts()`（配对过的全部 Mac，不管在不在线）；`pairedHostNames()` 改成由它算出的扩展方法；`RemoteGroupVouchTarget.hostInfo`。`RemoteMacDirectory` 的两个列表各读一次信任表，名字取 Mac 自己报的（不取别名和 Bonjour 名：会变，变一次就重签一次 `host`）。
- `RemoteDeviceGroupService.swift`：`start(hosts:)` / `tick` / `ensureModel` 把 `hosts` 交给模型（还没 `start` 时不拿 nil 冲掉）；`stop()` 取消还在问的请求；`isOpeningHosts` 时 2 秒一轮。
- 界面：`RemoteMyDevicesGroup`（Mac）、`RemoteMyDevicesScreen`（iOS）在组员名单下面加「还没通的 Mac」；文案在 `RemoteDeviceGroupCopy`（`pendingHostsHeader` / `pendingHostsFooter` / `pendingHostStatus`）。

### 记录

都由组员用 Ed25519 签名，签名覆盖除签名之外的每个字段；规范编码同 §12（标签在前、每个字段 LEB128 长度前缀）。可选的 `Data` 与 `Bool` 同可选字符串：先一个字节 0 / 1，有再放内容（`Bool` 是一个字节 0 / 1）。

| account | 内容（签名顺序） | 标签 |
| --- | --- | --- |
| `host.<Mac>.<签名者>` | host（id、name、X25519 公钥、model?、platform?）、signer、signerKey、signedAt | `"uTerm device-group host v1"` |
| `grant.<组员>.<Mac>.<签名者>` | deviceID、对象的 X25519、对象的 Ed25519、host（同上）、outcome、reason?、internetAccess?、relay?（封好的包）、signer、signerKey、signedAt | `"uTerm device-group grant v1"` |

- 解码时丢掉：钥匙长度不对、签名验不过；`host` 里 Mac 就是签名者；`grant` 里签名者就是对象（同一把 Ed25519）、签名者 ID 等于对象 ID、对象就是那台 Mac、outcome 为空、中继包为空。
- `signedAt` 取「现在」与签名者自己进组时间里晚的那个；收的一方只认签名者进组之后签的（同 `admit`，`RemoteGroupMembership.Signers.accepts`）。本机进组之前签的 `host` 会重签。
- outcome 是 `RemoteVouchResult.Outcome` 的原始值，另加 `unsupported`（Mac 太旧）。有定论 = `added` / `already-trusted` / `rejected`。
- 中继包：钥匙 = HKDF-SHA256(X25519(签名者远控私钥, 对象远控公钥), salt = `"uTerm device-group grant relay v1"`, info = `"relay"`, 32 字节)，协商出全 0 时抛错；ChaChaPoly；附加数据 = 规范编码的（标签、签名者 ID、对象 ID、Mac ID）。内容是 `RemoteRelayConfig` 的 JSON。开包用签名者在本机名单里的远控公钥，不用记录里自报的。

### 发、清理

- 只在组里（本机名单不空）时发：本机配对过的每台 Mac 一条 `host`（Mac 是本机自己的不发）；内容变了、或签于本机进组之前的重签；不再配对的删。只有自己一台时，本机签的 `host` / `grant` 全删。
- 本机签的 `grant`：对象已不是组员（ID 与两把钥匙对不上本机名单里的任何一台）、Mac 已不再配对，删掉。
- 被移出的设备什么都不发、不删（§7.1：不再写任何记录）。

### 问

每轮（`refresh()` 算完名单、核对完 Ta 之后，所以认下新设备的那一轮就问）：

- 对 `hosts.vouchTargets()` 里每台 Mac H（不是本机），没在问、不在冷却里，按「最近加入的组员在前」挑第一台需要问的组员 D 去问。D 是 H 自己、或 D 自称本机 ID 时不问。
- 需要问 = 名册里没有我认的组员（含本机）签的、针对 (D 的 ID 与两把钥匙, H 的 ID 与此刻的公钥) 的有定论的结果；有不定论的（不允许 / 太旧），签得离现在不到 6 小时也不问。
- 不同的 Mac 并行问；同一台 Mac 一次一个请求（`RemoteGroupVouchTasks`，按 Mac）。
- 连不上：不写，这台 Mac 60 秒内谁都不问。回来了结果（不论哪种）：这一对 60 秒内不再问。写名册失败：这台 Mac 冷却 60 秒。
- 问完时重新读本机状态：本机被移出、或 D 已不是组员，不写。写完马上再跑一轮（接着问这台 Mac 的下一个组员）。
- Mac 发了成员证书就封它；没发但 `internetAccess == true`，封本机给这台 Mac 单独记的中继（不是证书的那种）。
- 取消：模型释放（`RemoteGroupVouchTasks.deinit`）、服务 `stop()`、本机被移出，都取消还在问的请求；取消的那一次什么都不写（令牌对不上、或抛的是 `CancellationError`）。
- 没有远控私钥（`identityKey == nil`）不问。

### 收

- 对象是本机（ID 与两把钥匙）、Mac 不是本机、签名者是本机认的另一台组员且签于它进组之后的 `grant`。同一台 Mac 有几条：能用的优先，其次签得晚的，再按签名者钥匙排定。
- 能用就交 `hosts.adopt`：中继包打得开就带上，打不开（封给别人的、坏的、本机没有私钥）就不带。同一条结果、本机记着的这台 Mac 的公钥也没变时不再交（`adopt` 每次都读钥匙串）。
- 「还没通的 Mac」：组里知道的 Mac = 我认的其它组员签的 `host` + 写给本机的结果里的 Mac（本机除外），名字取签得最晚的那条。逐台：
  - 有能用的结果：`adopt` 给 `added` / `alreadyKnown` 不列；`conflict` → 「和这台设备记着的对不上，要重新配对」；`forgotten` → 「你在这台设备上忘记过它」。
  - 只有不能用的结果：本机自己配对过它就不列，否则按结果写原因：`not-allowed` → 「Mac 上没允许，要单独配对」；`unsupported` → 「Mac 上的 uTerm 太旧，要单独配对」；其余 → 「Mac 拒绝了，要单独配对」。
  - 没有结果：本机配对过就不列，否则「正在开通」。
- 刚由别的设备加进组的 10 分钟里、本机正在替别人问 Mac（10 分钟内开始的请求）时，`isOpeningHosts` 为真，服务 2 秒一轮。两个时间差都按绝对值算：钟不准、加入时间被写到将来、请求卡住，快轮询都不超过 10 分钟。

### 日志

别的设备写给本机的 `answer`（按 Tb）、`done`（按 Ta）、`admit`（按签名）、`grant`（按签名）第一次读到时记一行 `AppLogger.notice`：「设备组：读到 <写的设备 ID 前 8 位> 写给本机的 <种类>，写入后 N 秒读到」。模型建好后第一轮就在的不记。写入时间是对方的钟，差值里含两台的钟差。

### 界面

已进组、没被移出、`pendingHosts` 不空时，组员名单下面一组「还没通的 Mac」：每行 Mac 名字，右边一行字（「正在开通」灰色；要单独配对的 Mac 上用警示色）。footer：「组里有设备连得上这台 Mac 时，会自动替这台设备开通。」Mac 是 `SettingsListRow` + 右侧文字，iOS 是 `MInsetRow` 的 `value`。截图 `my-devices-pending-macs`（`SettingsPageSnapshotTests.testRenderMyDevicesGroup`）。

### 与 §7.2 不同、或 §7.2 没说的地方

- **不定论的结果对所有组员生效**：§7.2 只说「写结果，6 小时后再问」。不允许、太旧是 Mac 上的设置，别的组员问也是一样的答案，所以任何一台我认的组员 6 小时内写过，本机都不再问。
- **连不上按 Mac 冷却**（不是按「组员 × Mac」）：Mac 不在线时不用逐个组员各撞一次。
- **问完的这一对 60 秒内不再问**：§7.2 没有。没有它的话，结果写进去后读不回来（被钥匙串圈里的人删了、写失败）会立刻再问，变成循环。
- **只在组里时发 `host`，签名时间不早于本机进组**：§7.2 没说。只有自己一台时没人收；进组之前签的别人也不认（同 `admit`），进组后会重签。
- **「能用」的判断**：本机配对过这台 Mac（不管公钥）就算能用，除非有一条能用的结果、`adopt` 报了 `conflict`。忘记过的 Mac 在结果到之前显示「正在开通」（看不出来）。
- **没有远控私钥的设备不问**：问本身用不到私钥，但封不了中继包（brief 定的：没有私钥 = 不担保、不开包）。收照收，只是不带中继。
- **能用的优先可能挑到旧钥匙**：Mac 重装后，一台组员对旧钥匙的「能用」会压过另一台对新钥匙的「不允许」。`adopt` 不覆盖本机记着的公钥，最坏是本机收下旧钥匙、连不上。没处理。
- **`pairedHostNames` 变成扩展方法**，协议本身要的是 `pairedHosts()`。
- **服务的轮询测试改了**：`RemoteDeviceGroupServiceTests.test_polls_faster_while_showing_a_code_or_someone_wants_to_join` 里新设备收到回执后仍是 2 秒一轮（刚进组 10 分钟），不再立刻变慢。

### 仍然不严的地方

- **被偷的组员（移除之前）能让别的设备收下一台假 Mac**：它签一条对象是本机、outcome `added`、Mac 公钥是它自己的 `grant`，本机就把这把公钥记成一台 Mac，列在「我的 Mac」里，你可能往它的「终端」里打字。签名、签名者、时间都对，本机挑不出来。**移除这台组员之后，已经收下的假 Mac 不会被撤掉**（G2 不回滚收下的结果）。钥匙串圈里的冒充者做不到（签不出组员的签名，测试 `test_grants_from_outsiders_removed_members_tampered_or_for_others_are_ignored`）。
- 被偷的组员能写假的「有定论」结果，让别的组员不再替某台设备问某台 Mac（拒绝服务）。
- 问到一半时对象被移除：请求已经发出去，Mac 已经记下它；本机不写结果，但 Mac 那边要等 G3 的撤销。还没读到移除的离线组员也会照常替被移除的设备问。
- 中继配置只有签名者和对象打得开；签名者本来就是从 Mac 那里拿到这份配置的，没有多泄露。
- 继承自 G1a：离开记录被删掉时，原组的设备会继续认这台设备，进而认它在新组签的 `admit`，于是也会替新组的设备向原组的 Mac 开通（两组都是你的设备）。

### 测试

- `RemoteGroupHostRecordsTests`（8）：account；两种记录来回编解码、进快照；`grant` / `host` 的签名覆盖每个字段（逐个改，含 nil ↔ 有值、空串）；标签互不相同、签名搬不过去；解码丢掉替自己开通、替 Mac 向自己开通、空结果、空中继包、短钥匙、没签名、Mac 就是签名者；可选值编码无歧义；中继包只有那一对设备、绑定的那三个 ID 打得开，改一位、小阶点公钥都不行。
- `RemoteDeviceGroupHostsTests`（19）：组员认下新设备的那一轮就并行问两台 Mac、写签名的结果、新设备收下两台；没配对 Mac 的组员什么都不问；有定论后谁都不再问；替经别的组员加进来的设备问，别的组员已有定论的跳过；连不上 60 秒后再问、不允许和太旧 6 小时后再问；Mac 换钥匙再问、`host` 重签、新设备那边显示「对不上」；Mac 组员不替自己问、不列自己；慢的 Mac 不耽误快的，同一台 Mac 一次一个；模型释放、服务停止都取消请求且不写，回到前台再问；没有私钥不问、收的时候不带中继；中继包只有自己打得开、封给别人的和坏的都只是不带中继；冒充者、被移除的组员、改过字段的、写给别人的结果都不收、不进列表；签名者进组之前签的不收；能用的优先；「还没通的 Mac」从「正在开通」到各种原因再到空；被移出的设备不发、不收、不问，它的结果被签名者删掉，它被移出前替别人写的结果也不再被收；刚进组 10 分钟快、之后慢；卡住的请求最多快 10 分钟。
- `RemoteGroupHostAccessTests`（4，新增 1）：真服务端上两台设备经核对码组成设备组，组员在认下新设备的那一轮经已认证的连接替它担保、写下 `grant`，新设备的真 `RemoteMacDirectory` 收下这台 Mac，不经审批连上。目录测试多核了 `pairedHosts()`。
- `SettingsPageSnapshotTests.testRenderMyDevicesGroup`：加了「还没通的 Mac」（正在开通、没允许、太旧三行，通了的那台不列），浅色 / 深色。
- 用变异核过：收的时候不看签名者进组时间、问的时候只看自己写的结果、「能用的优先」去掉，各自对应的测试都红。

## 15. G3 落地

2026-11-16，分支 `claude/sibling-confirm-popup`。§7.3 的五块都接上了：移除之后请 Mac 撤销、同组撤销不拉黑、重装过的设备、组里的 Mac 互认、回滚只凭被移除的组员开通才记下的 Mac。

### 文件

- `uTerm/Features/Remote/RemoteDeviceGroup+Revoke.swift`（新）：撤销进度的记账与调度、「已移除的设备」、回滚收下的 Mac。
- `uTerm/Features/Remote/RemoteDeviceGroup+LocalHost.swift`（新）：本机是 Mac 时把组员记成自己的主控端、撤掉被移除的。
- `uTerm/Features/Remote/RemoteHostServer+DeviceGroup.swift`（新，mac-only：iOS 排除表里加了一行；远控进程的编译清单**没加**，它不需要）：`RemoteHostServer` 实现 `RemoteGroupLocalHost`。
- `RemoteDeviceGroup.swift`：`removedDevices`、`localHost`（弱引用）；`remove(_:)` 拆出 `writeRemoval(of:in:)`；`refresh()` 在核对完 Ta 之后调 `trackRevocations`，最后一步 `syncHosts` 改成 `inout`（会改撤销进度、收下的 Mac）。
- `RemoteDeviceGroup+Hosts.swift`：`syncHosts` 先做本机被控端那一步，再做撤销记账、发 `host`、清理、收、回滚、调度；`scheduleVouches` 换成 `scheduleHostWork`（撤销优先）；收的时候拆出 `acceptedGrants`。
- `RemoteDeviceGroup+Join.swift`：`retireOldIncarnations`（重装）；入组包不带新设备旧的那一份；新设备收下入组包时把包里的移除记成处理完。
- `RemoteGroupMembership.swift`：`admit` 的设备 ID 是本机的（本机重装之前的那一份）不认。
- `RemoteGroupLocalStore.swift`：`RemoteGroupRevocation`、`RemoteGroupAdoptedHost`，状态多两个字段（自己写的解码：老状态没有这两个键照样解得开，不当成空的）。
- `RemoteGroupHostAccess.swift`：协议加 `trustedHost(_:)`、`dropAdoptedHost(_:publicKey:pairedAt:)`；新协议 `RemoteGroupLocalHost` 与 `RemoteGroupLocalController`、`RemoteGroupTrustedHost`。`RemoteMacDirectory` 实现两个新方法。
- 被控端：`RemoteIdentityStore.revoke(id:blocks:)`；`RemoteHostServer` 的 `removeTrust(_:blocks:)`、`handleSiblingRevoke` 不拉黑、`groupAddController` / `groupDropController` / `handleGroupController` / `handleGroupDrop`、`groupControllerPolicy`；`RemotePeerVouch.isFromDeviceGroup(hostID:)`。
- XPC（只加不改）：`RemoteHostAgentCommand` 加两个 case，见下；`RemoteHostAgentService.perform` 处理它们。
- 界面：`RemoteMyDevicesGroup`（Mac）、`RemoteMyDevicesScreen`（iOS）加「已移除的设备」，移除确认多一句；`RemotePairedDevicesGroup` 显示「由设备组添加」；`RemoteVouchNotifier.post(_:hostID:)`；文案在 `RemoteDeviceGroupCopy`。
- 接线：`uTermApp` 设 `groupControllerPolicy`（远程控制开着 && 允许担保）、`deviceGroupService.start(hosts: remoteMacs, localHost: remoteServer)`；`RemoteDeviceGroupService.start(hosts:localHost:)` 把它交给模型。

### 移除之后请 Mac 撤销（A）

- **记账从本机的移除记录推出来**（`trackRevocations`，每轮都跑）：`state.removals` 里每条（不含本机签的离开、不含本机设备 ID）对应一条 `RemoteGroupRevocation`（按被移除的 Ed25519 钥匙）：设备 ID、远控公钥、名字、removedAt、要问的 Mac、做完的 Mac、每台 Mac 的再问时间。所以自己做的、读名册读到的、连带的、离线期间别人做的、重装留下的旧身份都一样处理，不看是哪个操作写的。
- 要问的 Mac = 第一次有 `hosts` 时本机配对过的 Mac（不含本机）；之后才配对的不问。同一把钥匙后来又被移除一次（重新加入后），从头再撤。名字取那一刻本机知道的（组员名单、名册里的 `admit` / `device`）。
- 结果：`revoked` / `not-trusted` / `not-in-family` = 做完；连不上：60 秒后再问，这台 Mac 60 秒内也不开通（共用 `hostFailures`）；Mac 太旧（`RemoteAttachError.rejected`）、认不出的结果：6 小时后再问。再问时间写在本机状态里（重启后还在）；写到很远将来的（钟往回拨）当作到期。
- 此刻还配对着的 Mac 都做完了 → 记成处理完（`hosts` 清空，记录留着当记号，不然下一轮又从头撤）。
- 调度：`scheduleHostWork` 对每台问得到、没在问、不在冷却里的 Mac，先挑最早移除的、到期的撤销；没有才开通。开通时跳过「这个设备 ID 在这台 Mac 上还有没做完的撤销」的组员（不管是不是在等再问）。撤销不要求本机在组里（移除最后一台别的组员后本机只剩自己），也不要求有远控私钥；被移除的设备自己在 `refresh()` 里早就返回，什么都不撤。
- 「已移除的设备」：`removedDevices`，每条还有 Mac 没撤完的移除一行（名字、还没撤的 Mac 名字）。

### 同组撤销不拉黑（B）

- `RemoteIdentityStore.revoke(id:blocks:)`，默认拉黑。`handleSiblingRevoke`（消息 52）下一拍执行 `removeTrust(_, blocks: false)`：删信任、删来路、吊销中继证书、断开，不拉黑；那一拍里被重新配对、换了钥匙的不撤。Mac 主人在 Mac 上撤销（`revoke`，含「撤销同一组的 N 台设备」）照旧拉黑。
- **连带**（G3 补，见下一节）：撤的不只是被点名的那台。
- **在哪执行**：连接在哪个进程，`handleSiblingRevoke` 就在哪个进程。App 里服务时直接写钥匙串；远控进程服务时写远控进程那份内存镜像（`RemoteMirroredSecretStorage`），每次写入经 `persistSecret` 回到 App 的钥匙串（App 不在时排队），App 的 `agentPersistedIdentity` 重读信任表与来路。App 那边带 `agent` 的 `RemoteHostServer` 没有连接，从不执行它。所以这一条没动 XPC。

### 同组撤销连带（G3 补）

不拉黑之后出现过一个反例（下文「仍然不严的地方」第一条的旧版）：被偷的 X 在被移除前替攻击者的 Y（它加进组的）、Z（谁都不知道的钥匙）担保过；组员撤 X 之后，Y 或 Z 马上把 X 担保回来，组员那边却记成做完。补法：

- **规则**（`RemoteVouchPolicy.cascade`，被控端在 `removeVouchedSubtree` 里执行）：同组撤销（消息 52）撤 X 时，连同此刻还被信任、`vouchedBy` 一层层追到 X 的设备一起撤，**发请求的那台除外**，也不顺着它往下走。每台都照普通撤销做：删信任、删来路、吊销它的中继证书、断开，都不拉黑。设备组撤掉被移除的组员（`handleGroupDrop`，组里的 Mac 自己）同样连带，没有要留的（请求者是 Mac 自己）。手动配对的设备没有担保记录，永远不在连带里（只有被点名的 X 自己可以是手动配对的）；拉黑的设备本来就不在信任表里，`revoke(blocks: false)` 也不解除拉黑。
- **为什么留下请求者**：X 往往是唯一一台在这台 Mac 上手动配对的设备，组里别的设备都是它担保的；全撤掉的话没人能再替正常的组员开通，只能到 Mac 上重新配对。请求者留着，它会替正常的组员重新开通（下一条）。
- **请求者的来路**（`RemoteVouchPolicy.reanchor`）：它的担保者在这次要撤的设备里时改挂：X 的担保者还在（没被撤、还被信任，或者就是这台 Mac 自己）就挂到它下面，否则挂在请求者自己身上（`vouchedBy == 自己`，成了这一组的锚点）。**组号不改**：`familyMembers` / `decideRevoke` 照旧把它和同组的设备算在一起，它照样能撤同组的设备、替同组担保（新担保的组号取它的组号）。`voucherName` 留着当初添加它的那台，设置里「由「X」添加」照旧（界面查担保者名字时跳过它自己）。改挂不改 `vouchedAt`，App 比对新记录时只看 `vouchedAt` 变没变，不会为改挂再发一次通知。改挂也去掉了「X → 请求者」这条旧边：X 以后重新进组、又被撤时，不会顺着旧边把请求者也撤掉。
- **组员一侧**：撤销结果的格式没变，`revoked` / `not-trusted` / `not-in-family` 照旧算做完。撤成功（`revoked`）时本机记下这台 Mac 的「重新算起」时刻（`revalidateFrom`，只在内存）：这之前签的开通结果对这台 Mac 都不算定论，开通那一步把每台组员再问一遍——还被信任的回 `already-trusted`，被连带撤掉的正常组员重新记下（被移除者签的结果本来也不算了）。新结果签在这个时刻之后，算定论，所以只补问一遍；撤不动（`not-trusted`）不补问。
- **组里的 Mac**（D）：`shouldDrop` 多一条：担保者是被移除的设备（组里此刻没有同一个 ID 的组员）、自己又不是组员的，也撤（Z 这类谁都不知道的钥匙）。撤的时候被控端连带；被连带撤掉的正常组员（本机签过能用的结果、此刻不被信任）一分钟后由本机重新记下。每轮重算，被移除的设备担保回来的下一轮又撤掉。`RemoteGroupLocalController` 为此多了 `vouchedBy`。
- 远控进程：规则在 `RemoteHostServer` 里，两种部署跑的是同一段代码；写入照常经 `persistSecret` 回到 App。XPC 没有再改。

### 重装过的设备（C）

- 组员核对完新设备的 Ta、认下它时（`advancePendingJoins`），名单里同一个设备 ID、钥匙不同的组员（重装之前的那一份）当场签 `remove`（`writeRemoval`，不连带），本机名单去掉它。之后照 A：各台组员先在 Mac 上撤旧钥匙、再开通新钥匙（同一个 ID 有没做完的撤销就不开通；B 让新钥匙不被旧的撤销挡住）。
- 入组包不带旧的那一份；新设备收包时也跳过设备 ID 是自己的条目；`RemoteGroupMembership.resolve` 不认设备 ID 是本机的 `admit`（旧的那份的移除还没读到时，别的组员补签的旧 `admit` 会被读到）。
- 别的组员读到新 `admit`、还没读到旧的那份的 `remove` 时，名单里同一个 ID 有两份钥匙：这期间谁都不替这个 ID 开通（`hasTwin`），不然 Mac 以「换过钥匙」拒绝，写下有定论的结果，之后没人再问。

### 组里的 Mac 互认（D）

- 条件（`syncLocalHost`，每轮一步，App 里做）：本机是 Mac、服务交进了它的被控端（`localHost`），本机没被移出。
  1. 撤：本机信任的主控端里，**经担保记下的**（有 `peerVouches` 记录：设备组或别的设备担保的）、设备 ID 与远控公钥就是本机记下的某条移除、此刻又不是组员的 → `groupDropController`（不拉黑）。本机不在组里了（离开、组里只剩自己）时，设备组记下的都撤。Mac 主人在这台 Mac 上手动配对的不动。撤先于记，每轮都重新判断（被重新担保回来的会在下一轮再被撤掉）。
  2. 记：本机开着「允许控制这台 Mac」和「允许担保」（`groupControllerPolicy`）、在组里时，最近加入的组员排前，挑第一台需要的：不是本机、没有同 ID 的另一份钥匙、没被 Mac 主人拉黑、60 秒内没问过；本机没信任它，或信任着同一把钥匙却还没有本机签的能用的结果 → `groupAddController`。本机信任着另一把钥匙的（手动配对过旧的那份）不替换。
  3. 写结果：成功（`added` / `already-trusted`，也包括手动配对过的组员）就写一条本机签的 `grant`：host = 本机（ID、名字、本机远控公钥、机型、`mac`），签名者 = 本机。中继：Mac 回了就封给那台组员（同 §7.2 的封法）。
- 被控端规则（`handleGroupController` = `handleVouch(request, voucherID: localID, voucherName: localName)`）：拉黑的拒绝、关了「允许担保」不加、已认识的公钥不同不替换；来路 `vouchedBy = family = 这台 Mac 的 ID`。公网接入照新配对设备的默认值：局域网审批配上的设备默认不开，`allowsInternetAccess(本机)` 恒为假，所以新加的不开、不发证书；已经认识、勾着公网接入的回 `already-trusted` 并照旧给证书。
- 设备组记下的这些算一组（组号是这台 Mac）：`familyMembers` 把它们列在一起，设置里「撤销同一组的 N 台设备」一起撤（拉黑，Mac 主人的决定）；它们之间可以互相请 Mac 撤销（消息 52，同组）；手动配对的组员请撤它们回 `not-in-family`，这台 Mac 自己会撤。设置里的来路显示「由设备组添加」（`isFromDeviceGroup`），通知写「设备组里的「X」现在可以远程控制这台 Mac」。
- 清理：本机签的、对象是组员的自己的结果不按「配对」删（本机不在自己的配对表里），只在对象不再是组员、或说能用但本机此刻不认它而且 Mac 主人拉黑过它时删。
- 收的一方：`grant` 的解码规则本来就接受「签名者就是那台 Mac」（只拒绝签名者是对象、对象是 Mac）；没改。收的时候多一条：**Mac 本身是组员时，结果里的公钥必须就是那台组员的远控公钥**（不管谁签的）。
- **App → 远控进程**：`RemoteHostServer.groupAddController` / `groupDropController` 在 `agent != nil` 时 `send` 新加的两个操作、等回复，否则在本进程执行。远控进程（`RemoteHostAgentService.perform`）解出请求，在自己的服务端上执行同样的 `handleGroupController` / `handleGroupDrop`；写入信任表、来路时照常经 `persistSecret` 回到 App（与配对、担保同一条路），所以远控进程内存里的信任表就是写入的源头，App 的钥匙串随后一致；中继证书在远控进程里签发并记到那台设备名下（`relayConfig(forPeer:)`），随信任表一起写回。App 读主控端列表（`groupControllerPeers`）直接读自己的钥匙串。远控进程不在、转不过去、或旧远控进程不认这两个操作（回 `ok: false`）都当成 nil：不写结果，这台 Mac 60 秒后再试。

XPC 新增（`RemoteHostAgentCommand`，只加不改，原有 case 与字段都没动）：

```swift
case groupAddController(Data)   // 负载 RemoteVouchRequest 的 JSON；回复 data = RemoteVouchResult 的 JSON
case groupDropController(Data)  // 负载 RemoteSiblingRevokeRequest 的 JSON；回复 data = RemoteSiblingRevokeResult 的 JSON
```

### 回滚只凭被移除的组员开通才记下的 Mac（E）

- 收结果时 `adopt` 回 `added`（之前本机不认识这台 Mac）：记一条 `RemoteGroupAdoptedHost`（Mac 的 ID、公钥、信任表里的记下时间、签名者的 Ed25519 钥匙）。回 `alreadyKnown` 的不记，永远不回滚。之后每轮把此刻所有我认的组员签的、针对同一 (Mac, 公钥) 的能用结果的签名者并进去。
- 每轮（`rollBackAdoptedHosts`）：本机信任表里这台 Mac 的公钥或记下时间变了（你重新配对过）、已经不在了（忘记过）→ 这条不再管。否则，如果此刻没有我认的组员签的能用结果、记下的签名者也没有一个还是组员，而且每个签名者本机都记着移除 → `hosts.dropAdoptedHost`。
- `RemoteMacDirectory.dropAdoptedHost`：公钥与记下时间（1 毫秒内）都对得上才拿；`identity.revoke(id:, blocks: false)`（不拉黑，所以之后 `adopt` 不会回 `forgotten`，别的组员再开通能记回来）；断开它的客户端、清掉给它共享的文件夹（`onForget`）。没用「忘记」：那会拉黑。

### 与 §7.3 不同、或 §7.3 没说的地方

- **要问的 Mac 在第一次知道本机配对了哪些 Mac 时定下**，不一定正好是认下移除的那一刻（服务还没交 `hosts` 时先空着）。
- **离开也算移除**：别的设备签的离开记录本机记成移除，同样去撤（离开的设备换了组，不再是这个组的设备）。
- **新设备不撤组里的旧账**：入组包里的移除记成处理完；只撤本机进组之后认下的。
- **认不出的撤销结果按 6 小时再问**；§7.3 只列了四种。
- **撤销不要求在组里、不要求有远控私钥**（§7.3 没说）；开通照旧要。
- **Mac 撤的范围**：§7.3 说「组员被移除：这台 Mac 自己把它撤掉」。实际只撤经担保记下的（设备组或别的设备担保的），Mac 主人手动配对的不动，和消息 52 的规则一致（手动配对的要在 Mac 上撤）。另加两条：Mac 离开组时撤掉设备组记下的全部；Mac 主人拉黑过的组员，本机签的「能用」结果删掉。
- **手动配对过的组员也写结果**（`already-trusted`）：§7.3 只说「记成主控端，然后给每台组员写一条 grant」。
- **公网接入**：§7.3 说照新配对设备的默认值，这里落成「不开」（局域网审批的默认），已经勾着的照给证书。
- **收的时候多一条公钥绑定**（Mac 本身是组员时）和**同 ID 两份钥匙时谁都不开通**、**不认本机 ID 的 `admit`**：§7.3 没有，是 C、D 带出来的。
- **「已移除的设备」在不在组里都显示**（移除了最后一台别的组员之后也要看得到进度），被移出的设备不显示。一行写「「X」还没撤销」（只剩一台）或「还有 N 台 Mac 没撤销」。
- G1a 记下的风险「同一个 ID 的 `admit` / `remove` account 互相覆盖」：重装时新旧两份的 `admit` 仍落在同一个 account 上。别的组员读到新 `admit`、还没读到旧的移除的那几秒里，本机补签会在两份之间来回改写这一条（读到移除后停）；`remove.<ID>.<签名者>` 之后若再移除新的那份会覆盖旧的那条，已经读到的设备本机记录不受影响，新进组的设备从入组包拿移除记录。

### 仍然不严的地方

- **（已补）同组撤销不拉黑带出的反例**：被偷的 X 替 Y、Z 担保过，组员撤 X 后 Y / Z 把 X 担保回来。现在撤 X 一次就连带撤掉 Y、Z（它们都由 X 担保），三台都不再被信任，谁也担保不回谁（见上「同组撤销连带」，测试 `test_family_revoke_takes_everything_the_revoked_device_vouched_with_it`）。
- **（已补，§18）攻击者抢先撤销**：Mac 分不清 X 担保过的设备里哪台是你的、哪台是攻击者的，原来谁先撤 X 谁留下。
  - M 不在 X 担保的那一串里（比如 X 是 M 担保的）：攻击者的 Y 抢先撤 X，那一串里只有 Y，Y 留下（来路改挂到 M），M 随后撤 X（`not-trusted`）、撤 Y（比 M 晚，`revoked`，连带 Y 担保的）→ Mac 上干净。测试 `test_attacker_revoking_first_keeps_itself_only_until_an_ancestor_revokes_it`。资历规则下不变。
  - X 是这台 Mac 上唯一手动配对的，M 和 Y 都是 X 担保的：原来 Y 抢先撤 X → X 和 M 被连带撤掉、Y 留下，M 没有信任了撤不了 Y。现在按资历：留下的是那一串里最早加到这台 Mac 的 M，Y 连同它担保的一起撤掉（回执先发给 Y）；Y 也撤不了比它早、又不是它上游的 M（`not-senior`）。测试改成 `test_attacker_revoking_first_takes_itself_out_and_the_earliest_sibling_stays`。规则与仍然不严的地方见 §18。
- **被撤的设备再来连会弹审批框**：被连带撤掉的设备（包括正常的组员）手里还记着这台 Mac，下次连局域网会让 Mac 弹配对审批框，直到组员替它重新开通。和以前被撤销的设备一样，没处理。
- **手动配对过、但以前被担保过的设备**：手动配对审批不清它的担保记录，它仍算「经担保记下的」，会被连带撤掉（不拉黑，会被重新开通）。
- 组员一侧的「重新算起」只在内存（§18 起撤的时候 Mac 回 `not-trusted` 也算起）：撤成功之后、补问完之前 App 被结束，被连带撤掉的正常组员要等别的组员发现（被移除者签的结果不算后，有定论的结果没了才会再问）；请求者签过的定论还在的那几台不会被再问。
- 组里的 Mac 认所有组员：被偷的组员在被移除前加进组的设备，会被组里每台 Mac 自动记成主控端。这和 G2 一样（被偷的组员加的设备，诚实的组员也会替它向各台 Mac 担保），没有扩大；移除后组里的 Mac 每轮撤掉它们。
- 回滚只认「收下那一轮本机记下」的条目：收下之后、存状态之前 App 被结束，这条就没记上，以后不会回滚。
- 重装规则：谁让组员输了它屏幕上的数，谁就能把一台已有组员（同一个设备 ID）顶下去。只能让那台组员被移除（要重新加入），拿不到控制权。

### 测试

- `RemoteDeviceGroupRevokeTests`（16，新）：移除后每台配对过的 Mac 各撤一次、带被移除那台的远控公钥，「已移除的设备」从「还有一台」到空，撤完不再问，没配对 Mac 的组员和被移除的设备自己都不撤；连不上 60 秒、太旧 6 小时、`not-in-family` / `not-trusted` 算做完；离线期间发生的移除回来照样撤；连带的每一台都撤；移除最后一台别的组员后照样撤、之后才配对的 Mac 不问；新进组的设备不撤组里的旧账；重装：认下新的同时移除旧的（不连带），撤不了的时候不开通新钥匙，撤了之后「先撤旧钥匙、再开通新的」，别的组员、新设备的名单都对；Mac 组员：不在组里 / 没开开关不记，开了只记没被拉黑的，写本机签的结果、对方收下这台 Mac；远控进程不在时不写、一分钟后再试，手动配对过的写 `already-trusted`、来路不改；被移除的组员撤掉不拉黑、手动配对的不动；Mac 主人拉黑后结果删掉、不再加回；Mac 离开组撤掉设备组记下的；冒用组员 Mac 的 ID、换了公钥的结果不收；被偷的组员签的假 Mac 在它被移除后拿掉、不算忘记、之后别的组员开通能记回来；两台组员都开通过的、本机早就认识的不回滚。
- G3 补（同组撤销连带）：`RemoteVouchTests` 加 7（连带撤掉 X 担保的 Y、Z、M2，都不拉黑，M 留下、M2 能再开通，Y、Z 再连要审批；只有 X 手动配对时 M 留下、来路改挂、组号不变、不发通知、能再开通 M2 也能撤它；攻击者抢先撤的两种情况；连带不碰手动配对、不解除拉黑；组里的 Mac 撤被移除的组员时连带；`cascade` / `reanchor` 的纯规则，含环）；`RemoteDeviceGroupRevokeTests` 加 2（组里的 Mac 撤掉被移除组员担保的 Z、被连带的正常组员记回来、被担保回来的下一轮再撤；组员撤成功后把这台 Mac 上的组员补问一遍、只一遍，`not-trusted` 不补问），重装那条改成「撤成功之后只有开通」；`RemoteHostAgentTests` 的设备组那条加上：远控进程里撤组员时连带撤掉它担保的 Z，写回 App、不拉黑。
- `RemoteVouchTests`（22，改 1 加 5）：同组撤销不拉黑、之后能再担保并免审批连上，Mac 主人撤销照旧拉黑；同组撤销解不开 Mac 主人的拉黑；Mac 按设备组记下的来路、组号、通知、免审批，设备组记下的两台可以互相撤；拉黑的不加、不换钥匙、关了担保不加；撤被移除的组员不拉黑、能再加回来，手动配对的回 `not-in-family`。
- `RemoteGroupHostAccessTests`（6，加 2）：真服务端：Mac 组员（模型的被控端就是真服务端）认下新 iPad、写结果，iPad 的真目录收下、免审批连上，移除后 Mac 撤掉它、不拉黑；重装：iPhone 先在真服务端上撤旧钥匙、再替新钥匙开通，新 iPad 免审批连上。
- `RemoteHostAgentTests`（14，加 1）：经匿名 XPC 监听器的远控进程：`groupAddController` 转过去、写回 App、来路是设备组、发通知、免审批连上；`groupDropController` 撤掉、断开、两边都没拉黑、能再加回。
- `RemoteDeviceGroupCopyTests`（8，加 2）：「已移除的设备」一行的文案；G3 之前存的本机状态照样解得开。
- `SettingsPageSnapshotTests.testRenderMyDevicesGroup`：加 `my-devices-removed-devices`（一台只剩一台 Mac 没撤、一台两台没撤），移除确认多了一句，浅色 / 深色。
- 用变异核过：去掉「同一个 ID 有没撤完的撤销就不开通」、去掉「组员 Mac 的公钥绑定」，各自对应的测试都红。

## 16. G4a 落地

2026-11-17，分支 `claude/sibling-confirm-popup`。§7.4 的叠加层、同步、局域网线路接上了；中继信箱是 G4b。上层（`RemoteDeviceGroup`、加入协议、组员名单）的逻辑没改，只是 `live` 建的名册换成了包着叠加层的那份；名册的 JSON 编码改成按键排序（见「与 §7.4 不同」）。被控端、远控进程、XPC 协议都没碰，新文件也没进远控进程的编译清单。

### 文件

- `uTerm/Core/Remote/RemoteGroupOverlayStorage.swift`（新）：叠加层 `RemoteGroupOverlayStorage`（实现 `RemoteSyncedStorage`，`.live` 全 App 一份）、墓碑 `RemoteGroupTombstone`、`RemoteGroupRecord.writtenAt` / `kind`。
- `uTerm/Core/Remote/RemoteGroupFastSync.swift`（新）：线路抽象 `RemoteGroupPeerLink`、`RemoteGroupLinkKind`、消息 `RemoteGroupSyncMessage`、同步层 `RemoteGroupFastSync`（含日志）。
- `uTerm/Core/Remote/RemoteGroupLANLink.swift`（新）：握手与逐帧加密 `RemoteGroupLANHandshake` / `RemoteGroupLANCipher` / `RemoteGroupLANFrameReader`，一条连接 `RemoteGroupLANConnection`（握好手就是一条 `RemoteGroupPeerLink`）。
- `uTerm/Features/Remote/RemoteGroupLANService.swift`（新）：Bonjour 听与找、谁发起、去重、退避重连。
- `uTerm/Features/Remote/RemoteGroupFastChannel.swift`（新）：同步层 + 局域网服务；`live(for:)` 在测试宿主、没有远控私钥、名册不是叠加层时返回 nil。
- `RemoteDeviceGroup.swift`：`live` 用 `RemoteGroupRoster(storage: RemoteGroupOverlayStorage.live)`。
- `RemoteDeviceGroupService.swift`：持有快通道（`makeFastChannel` 可注入），轮询在跑、模型有了就开，`stop()` 关；收到新东西在主线程合并成一次 `refresh()` + `wakeUp()`。
- `Info.plist`、`uTermMobile-Info.plist`：`NSBonjourServices` 加 `_uterm-group._tcp`。

### 叠加层

- `save`：写钥匙串；解得开、不超过 16 KiB 的同时记进叠加层（account 取 `RemoteGroupRecord.account`，不信调用方给的），通知 `.local`。太大的、解不开的只进钥匙串。
- `delete`：先读一次钥匙串，记下这个 account 此刻的内容（钥匙串里的、叠加层里的），删钥匙串，对每一份留墓碑（account + SHA-256 + 删除时间），通知 `.local`。
- `loadAll`（= `snapshot().items`）：钥匙串的每条按解出来的 account 分组；叠加层每个 account 最多一条。被墓碑命中的两边都不出。叠加层那条和钥匙串某条一样 → 丢叠加层那条；比钥匙串最新的那条新 → 只出叠加层那条（同一 account 钥匙串那几条都藏起来）；否则丢叠加层那条。读的时候发现钥匙串的内容集合变了，通知 `.base`。
- 「新」怎么比：先比记录里写入者自己的时间（`writtenAt`：`device.updatedAt`、`join/answer/done.createdAt`、`admit/host/grant.signedAt`、`remove.removedAt`），不同就按它；相同再比本机第一次见到这份内容的时刻（钥匙串那份按第一次读到，叠加层那份按收到）。见下「与 §7.4 不同」。
- 叠加层和钥匙串对同一 account 一直不一样、叠加层赢着超过 10 分钟，以钥匙串为准（丢叠加层那条）。
- `ingest(records:tombstones:from:)`：墓碑先收（摘要 32 字节、account 非空且不超过 256 字节；已过期的、本机删了又写回去的不收；删除时间写在将来的按现在算），命中的叠加层条目当场丢。记录：超 16 KiB、解不开、被墓碑命中、已经有了、**本机 10 分钟内见过的**（被换掉的旧内容、被拒过的）都不收；比此刻这个 account 的内容旧也不收。返回实际收下的，非空时通知 `.received`。
- 墓碑：在 `deletedAt + 10 分钟` 作废（按收到的一方的钟；不按「收到起 10 分钟」，否则两台设备互相转手会一直续下去）；最多 512 个，超了丢最早的。本机删了又写回同一份内容时，这份内容的墓碑在本机去掉，10 分钟内别的设备转回来的同一个墓碑不理。
- 上限：叠加层 512 条，超了丢最早收到的非本机写的（全是本机写的才丢本机的）。见过的内容摘要（解码缓存）在用的一直留，不在用的 10 分钟后忘，最多 4096 个。
- `baseDevices()`：只解钥匙串那份里的 `device`，快通道的准入只看它。
- 线程：一把锁，观察者回调在锁外、在调用方的线程上。

### 线路抽象

```swift
nonisolated protocol RemoteGroupPeerLink: AnyObject, Sendable {
    var peer: RemoteGroupDevice { get }          // 钥匙串名册里、用远控公钥证明过身份的那台
    var kind: RemoteGroupLinkKind { get }        // .localNetwork / .relay（日志用）
    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
    func send(_ frame: Data)
    func close()
}
```

实现要保证：帧按序、不重不漏，重放 / 乱序 / 被改的直接断开；单帧至少装得下 `RemoteGroupFastSync.maxPayload`（48 KiB）；`activate` 之前收到的帧先存着。G4b 的中继信箱写一个实现，握好手后交给 `RemoteGroupFastChannel.sync.add(_:)`。

### 消息（`RemoteGroupSyncMessage`）

JSON `{v:1, type:…}`，`Data` 是 base64；版本不对、类型不认识、解不开的整条忽略（不断开）。

| type | 字段 | |
| --- | --- | --- |
| `sync` | `have`（32 字节摘要首尾相接）、`dead`（墓碑的 `key` = SHA-256(account ‖ 0 ‖ 摘要)）、`reply`、`more` | 我见过的全部内容（全集 + 10 分钟内见过、已被换掉或拒掉的）与我的墓碑。一条最多 1000 个摘要，多了分几条，前面的 `more` 为真；对端累计超过 16384 个就断开 |
| `records` | `records`：原始记录字节 | 按编码后大小切批，一批不超过 48 KiB |
| `tombstones` | `tombstones`：`{account, digest, deletedAt}` | 同上 |

- 每条线路：接上时发 `sync`；收到不带 `reply` 的 `sync` 回一条带 `reply` 的。收完一次完整的 `sync` 之前不主动推（不知道对方有什么）。之后 `peerHas` / `peerDead` 换成对方报的，把对方没有的记录与墓碑推过去。
- 叠加层有任何变化（本机写删、收到、钥匙串变了）50 毫秒合并一次，对每条线路推对方还没有的。收到的记录、墓碑先记成「对方有」再收，所以不回声；推过去的也记上。每 30 秒再发一次 `sync`。
- 同一台对端已有线路时，新接上的替掉旧的（局域网服务自己先挑好一条）。
- 日志：`设备组：经局域网收到「<对端名字>」的 <kind>，写入后 N 秒`（N = 现在 − `writtenAt`，含两台的钟差）；一次超过 6 条只记一行汇总（`… 的 N 条记录（admit ×3、device ×4）`）；墓碑另记一行条数。经快通道收下的记录，钥匙串后来也送到同一份时叠加层再记一行 `设备组：钥匙串也送到了快通道先收到的 <kind>，晚 N 秒`。注意 §14 那条 `读到 … 写入后 N 秒读到`（`noteArrivals`）读的是合并后的名册，现在量的是两条路里先到的那一趟，不再只是钥匙串。

### 局域网线路与握手

- Bonjour `_uterm-group._tcp`，服务名是设备 ID，TXT `id = 设备 ID`。`RemoteLink.parameters()`（TCP、关 Nagle、keepalive、8 秒建连超时）。
- 谁发起：两台都在浏览结果里时，设备 ID 字符串小的那台；大的那台发现对方 5 秒后还没连上才自己发起（单向发现）。两条都连上时两边按同一条规则留一条：发起方是 ID 小的那条优先，同一方发起的留新的。名册里还没有对方的 `device` 时不发起。
- 分帧：4 字节大端长度；握手完成前一帧最多 4 KiB，之后 256 KiB；长度 0 或超限立刻断开。
- 握手：
  1. 发起方 I → R：hello `{v:1, id, key（远控公钥）, nonce（32 字节）}`；R 核对：不是自己，`id` 在**钥匙串**名册里有 `device` 且 `publicKey == key`（同一个 ID 有几条时任一条对得上即可），否则不回、断开。R 回自己的 hello；I 核对它就是要连的那台（Bonjour TXT 里的 ID）、同样在名册里。
  2. 抄本 = I 的 hello 原字节 ‖ R 的 hello 原字节。共享秘密 = X25519(本机远控私钥, 名册里对方的公钥)，全 0 拒掉。两个方向的密钥 = HKDF-SHA256(共享秘密, salt = nonceI ‖ nonceR, info = `"uTerm device-group lan v1 i2r|r2i <I 的 ID> <R 的 ID>"` ‖ SHA-256(抄本))。
  3. 之后每帧 ChaChaPoly：明文 = 1 字节类型（1 业务、2 证明、3 探活）+ 内容；随机数 = 4 字节 0 + 8 字节大端帧序号（每个方向自己数，不随帧发）；AAD = `"uTerm device-group lan frame v1"`；线上只有密文 ‖ 16 字节标签。
  4. 证明帧：内容 = SHA-256(`"uTerm device-group lan proof v1"` ‖ SHA-256(抄本))，必须是各方向的第 0 帧。I 发完 hello 核对后先发；R 核对过才回自己的；两边都核对过才算建立，才收业务帧。握手 10 秒不完就断。
- 建立之后：15 秒没发过东西就发一个探活帧，45 秒什么都没收到就断开；交给同步层之前最多存 256 帧。断开后按退避重连（1 秒起翻倍、最多 30 秒，连上清零；连上后断开从 1 秒起），每秒检查一次。浏览结果里消失的对端不再重连；已建立的线路靠探活收尾。
- 接受方最多同时 8 条在握手的连接。

### 起停

- `RemoteDeviceGroupService`：`tick()` / `ensureModel()` 在轮询在跑、有模型、还没有快通道时调 `makeFastChannel(model)` 并 `start()`；`stop()` 停掉并丢掉（下次 `start` 重建）。Mac 上 App 开着就开，iOS 跟着前后台。默认的 `RemoteGroupFastChannel.live` 在 `RemoteLocalState.isIsolated`（测试宿主）、模型没有远控私钥、名册不是叠加层时返回 nil；App 本来就不在测试宿主里启动这个服务。
- 收到新东西（`RemoteGroupFastSync.Received`）→ 主线程上合并成一次 `refresh()` + `wakeUp()`。本机自己的写入不触发（否则 refresh → 写 → refresh 循环）。

### 与 §7.4 不同、或 §7.4 没说的地方

- **「后到的」先比写入者自己的时间**。§7.4 只说按到达时刻（钥匙串那份按第一次读到）。只按到达会回退：B 经快通道先收到 v2，C（还没见过 v2、从自己的钥匙串读到 v1）再把 v1 转给 B，v1 就「后到」赢了，而且之后谁也纠正不了（B 见过 v2，不会再收它）。同一个 account 永远是同一台设备写的（`device.<自己>`、`join.<自己>`、`answer.<新设备>.<自己>`、`admit.<设备>.<自己>`……），它自己的钟是单调的，所以先比它。写入时间相同才按到达。代价：写入者的钟往回拨过时，它的新内容在别的设备上会输给旧的，直到下一条兜底。
- **叠加层与钥匙串一直不一样 10 分钟后以钥匙串为准**（§7.4 没有）：兜住上一条的代价，也兜住钥匙串圈里的人写一条时间在将来的记录、让叠加层一直赢。
- **见过的内容 10 分钟内不再收**：被换掉的旧内容、被拒过的，对端再送也不收；`sync` 里的 `have` 也报这些，对端就不再推。
- **墓碑按删除时间过期**（不按收到时间），删除时间写在将来的按收到时算；本机删了又写回同一份内容时，别的设备转回来的旧墓碑本机不理。
- **墓碑也藏钥匙串里同一 account 下的全部旧内容**：删除前读一次钥匙串，按解出来的 account 找；钥匙串圈里的人在别的 keychain account 下放的同 account 副本也一起藏 10 分钟。
- **`sync` 报摘要不报 account**：§7.4 写的是 `(account, sha256)`。比对只要摘要，带上 account（最长 117 字符）一千多条就超过中继的一帧；墓碑在 `sync` 里只报 `key`，内容由对方缺什么推什么。
- **收到的东西直接推，不等对方来要**：§7.4 写「对方回它有而我没有的记录，并要它没有的」。现在每条线路记着对方有什么（它报的 `sync` + 双方送过的），有变化直接推缺的，一跳就到；`sync` 只在接上时和每 30 秒对一次账。
- **局域网的 hello 带公钥**：§7.4 只说「用对方记录里的公钥」。名册里同一个 ID 可能有几条（钥匙串圈里的人能写），带上公钥就不用逐条试；核对的仍是「名册里有这个 ID + 这把公钥」。
- **发起方规则的兜底**：大的一方 5 秒后也发起、两条都通时按规则留一条（§7.4 没说）。
- **日志里的设备名是线路对端**（转手的记录，写入者不一定是它）。
- **名册的 JSON 改成按键排序编码**（`RemoteGroupFormat.encoder()` 加 `.sortedKeys`）：JSONEncoder 默认的键序每次编码不一定一样（测试里真的碰到过），同一条记录重写一遍字节就变，叠加层按字节摘要认「同一份」，墓碑、去重、「钥匙串追上了」都会失灵。解码不受影响，老版本写的记录照读。

### 仍然不严的地方

- **钥匙串圈里的人能把删除扩大成 10 分钟**：它能进快通道（它的 `device` 本来就在名册里），发一个墓碑就能把任何一条记录在所有设备上藏 10 分钟（钥匙串里也能删，但写的一方会马上写回来；墓碑让写回来的那份在别的设备上也被藏着，本机删了又写回才不理）。和 §12「拒绝服务」同一类，影响比只靠钥匙串大一点。
- **写入者的钟往回拨**：它新写的内容在别的设备上最多晚 10 分钟（加上钥匙串那一趟）才生效。
- **没有前向保密**：会话密钥由两把长期 X25519 钥匙和两个随机数派生，长期私钥泄露后录下的流量解得开。内容本来就是同一钥匙串圈里都读得到的名册，记录各自的签名 / CPace 照旧。
- **局域网上谁都能连上来握一次手**：名册外的连接在 hello 之后就断，但每条都要读一次钥匙串（`baseDevices()`）；最多同时 8 条在握手。
- **对端的 `device` 记录后来才到**：靠退避重试（最多 30 秒一次）补上，没有「钥匙串一变就重连」。
- **一台设备两个进程**：快通道只在 App 里（远控进程不读名册），App 开着两个实例的情况没管（全 App 只有一个服务）。
- **叠加层最多 512 条**：一台新设备的钥匙串是空的、组里记录又超过 512 条时，第一次连上收不全（先收到的被挤掉，10 分钟内对端不再重发），其余等钥匙串。眼下的组远没有这么多记录。
- **没在真机上验**：iOS 的本地网络授权、Wi-Fi 切换、两台手机之间的局域网连通性、和远控 / 局域网同步的 Bonjour 一起跑，都要在装好的包上试；日志里比「经局域网收到 … 写入后 N 秒」和「读到 … 写入后 N 秒读到」两行。

### 测试

- `RemoteGroupOverlayStorageTests`（14）：写钥匙串并报 `.local`、只出一份；account 以记录为准；同一条记录每次编出同样的字节；删除留墓碑、另一台钥匙串还有时被藏住、再送不收；墓碑不挡同 account 的新内容（收到的、本机写的）；墓碑 10 分钟作废、过期的转回来不收、写在将来的也只留 10 分钟；删了又写回时不理转回来的墓碑；后到的赢、钥匙串追上后叠加层那条丢掉；旧的后到不回退（钥匙串慢半拍、别的对端转来写得更早的）；不一样 10 分钟后以钥匙串为准；钥匙串变化只报一次；上限丢最早的非本机写的；垃圾、版本不对、种类不认识、超 16 KiB、长度不对、坏墓碑都不收（太大的本机记录只进钥匙串）；叠加层来的 `device` 列得出来、但不算名册设备。
- `RemoteGroupFastSyncTests`（8，内存线路）：两台连上互相补齐、之后的变化一推就到、上层收到回调；A—B—C 链式转手记录与删除、C 的钥匙串慢半拍送来被删的记录也藏住、反方向也转手；B 不把从 A 收到的原样回给 A；40 条大记录分批、每帧不超过 48 KiB；1050 个摘要的 `sync` 分条；不认识的消息、版本不断开；断开后重连补齐；消息编解码。
- `RemoteGroupFastJoinTests`（4，`RemoteDeviceGroup` 端到端，各自的钥匙串互不同步、只预先放好大家的 `device`）：两台只靠快通道走完加入 → 输码 → 进组 → 回执；A—B—C 链式，C 经 A 加入时每一步由 B 转手，三台名单收敛；加入之后钥匙串慢半拍送到（先是含早已撤下的 `join` 的一段，再是全部）不弹旧请求、名单不变、不出重复 account；服务只在后台轮询在跑时开快通道、只建一个、`stop()` 关掉，收到新东西马上读（不等 10 秒那一拍）。
- `RemoteGroupLANLinkTests`（11，真 `NWListener` + `NWConnection` 走回环）：两台握手、双向收发记录、不写钥匙串；对端的 `device` 后来才到时重试连得上；发起方不接受不是要连的那台；名册外的（叠加层收到过它的 `device` 也不算）hello 之后断开、塞的 `join` 进不了名册；hello 的公钥和名册对不上断开；报了名册里的 ID 和公钥但没有私钥，证明帧过不了、之后的业务帧也进不了名册；抄本被改证明帧过不了；同一会话重放业务帧断开、新会话里重放上一次的证明帧断开（重放之前那条照收）；握手前超 4 KiB、握手后超 256 KiB 的帧断开；逐帧加密拒乱序、被改、重放；小阶点公钥拒掉。

## 17. G4b 落地

2026-11-17，分支 `claude/sibling-confirm-popup`。§7.4 的中继信箱接上了：两台设备不在同一网络时，名册记录经用户自建的中继直接送到。中继服务端一行没改（线上 1.3.0 照用）；被控端、远控进程、XPC 协议没碰，新文件也没进远控进程的编译清单。上层（`RemoteDeviceGroup`、加入协议、组员名单）没改。

### 文件

- `uTerm/Core/Remote/RemoteGroupRelayLink.swift`（新）：信箱 ID 与钥匙 `RemoteGroupMailbox`；信令 `box` 的编解码 `RemoteGroupRelayBox` / `RemoteGroupRelayHello`；密钥、抄本、证明、分片 `RemoteGroupRelayHandshake`；重组 `RemoteGroupRelayReassembler`；一条线路 `RemoteGroupRelaySession`（握好手就是一条 `RemoteGroupPeerLink`，`kind = .relay`）。
- `uTerm/Features/Remote/RemoteGroupRelayService.swift`（新）：控制连接抽象 `RemoteGroupRelayControl` / `RemoteGroupRelayDialer`，真实网络的 `RemoteGroupRelayNetworkDialer` / `RemoteGroupRelayNetworkControl`（复用 `RemoteRelayConnection` 的分帧与认证、`RemoteRelayRequest.member`、`RemoteRelaySignature`），服务 `RemoteGroupRelayService`（信箱注册、投递、拨号、去重、心跳、退避、跟配置）。
- `RemoteGroupFastSync.swift`：`RemoteGroupLinkKind.priority`；`add` 按种类挑线路、换线路时沿用对端「有什么」的账；`onLinkClosed`（对端没有线路了才报）；`linkKind(for:)` / `linkKinds`。
- `RemoteGroupFastChannel.swift`：多了 `relay`（`Options` 可注入，`live` 用 `.live()`）；`stop()` 改成先停同步层再停两条线路的服务。
- `RemoteGroupLANLink.swift`：`RemoteGroupLANCipher` 的 AAD 可传（中继那套用自己的标签），局域网照旧。
- 文档：`relay/PROTOCOL.md` 加「设备组信箱」，`relay/README.md` 的「限制」带一句名额，`CLAUDE.md` 补落点。`scripts/test-relay-e2e.sh` 多跑一个类。

### 信箱 ID 与钥匙

- 信箱的主机 ID = SHA-256(`"uterm-group-mailbox-v1"` ‖ 设备 ID 的 16 字节) 的前 16 字节，版本位改成 8、变体位改成 RFC（`RemoteGroupMailbox.hostID(for:)`）。设备 ID 是随机的 v4，版本位不同，两者永远不相等；每台设备都能从名册里别人的设备 ID 算出别人的信箱。算法改了就是协议变更（测试钉着一个向量）。
- 信箱钥匙是一把 P-256，存 `RemoteLocalState.secrets`（钥匙串 service `com.uozi.uTerm.remote`，account `groupMailboxKey`，`ThisDeviceOnly`），第一次用时生成。和远控的 `relayHostKey` 分开。没放进 `RemoteIdentityStore`：那个文件编进远控进程，`RemoteGroupMailbox.hostKey(storage:)` 照它的写法另写一份。
- 默认中继配置每 30 秒读一次 `RemoteRelayConfigStore().load()`；没有、是成员证书、配置无效时整条中继线路不开（各记一行原因，同样的原因不重复记）；换了配置（任何字段）就收掉全部线路和两条控制连接重来。

### 两条控制连接

- **信箱**：`host` 注册（成员密钥签 `sig`，信箱钥匙签 `hostSig`）。收到的 `signal` 交给拨进来的线路；`incoming` 不理；`superseded` 断开，不马上重连。
- **投递**：一条 `client` 连接。连上马上 `list`，之后每 15 秒一次；在线的、钥匙串名册里登记过的设备才拨。每台对端在这条连接上固定用一个随机 session（中继给每条 `client` 连接最多记 64 个 session、从不忘），重拨在同一个 session 上重新握手；最多 60 台对端。
- 两条都是 60 秒 ping 一次、20 秒没有回音就断开重连（只认中继本身的回答）；断了按 1 秒起翻倍、最多 60 秒重连。被拒（`full`、`hostKey`、认证不过、读不到信箱钥匙）和被顶替：5 分钟起翻倍、最多 1 小时再试，日志各记一行（`hostKey` 那行带信箱 ID，方便在中继上 `forget`）。网络一变（`RemoteNetworkWatcher`）两条都立即重连、退避清零。
- 真实连接的发送走一个按序的任务（`AsyncStream`）：密封帧带序号，两个 `send` 被调度乱了对端就解不开。`close()` 先把排着的发完（最多等 2 秒）再断，所以收线路时的 `bye` 发得出去。

### 握手与密封

拨的一方 C，信箱主人 M。`box` = base64(1 字节种类 ‖ …)：

| 种类 | 内容 | 方向 |
| --- | --- | --- |
| `hello` (1) | 版本、链路号 8 字节、C 的随机数 32、C 的远控公钥、C 以为的 M 的远控公钥 | C → M |
| `reply` (2) | 版本、链路号、M 的随机数 32 | M → C |
| `sealed` (3) | 链路号、ChaChaPoly 密文 ‖ 16 字节标签 | 双向 |
| `reset` (4) | 链路号（不加密） | M → C |

1. M 只在这些都对上时回：信令外层的 `from`（C 的设备 ID）在**钥匙串**名册（`overlay.baseDevices()`）里有 `device`、记录的公钥就是 hello 里那把、hello 里 C 以为的 M 的公钥就是本机的、不是自己。否则一个字都不回。同时在握手的拨入最多 16 条；和这台对端连着局域网时也不回。
2. 抄本 = `"uTerm device-group relay v1"` ‖ session（2 字节长度 + UTF-8）‖ C 的设备 ID ‖ M 的设备 ID ‖ hello 原字节 ‖ reply 原字节。共享秘密 = X25519(本机远控私钥, 名册里对方的公钥)，全 0 拒掉。两个方向的密钥 = HKDF-SHA256(共享秘密, salt = C 的随机数 ‖ M 的随机数, info = `"uterm-group-sync-v1 relay c2m|m2c"` ‖ SHA-256(抄本))。session、方向、两端设备 ID、两边的随机数都在里面，换了任何一个都解不开。
3. 之后每帧 ChaChaPoly（就是 `RemoteGroupLANCipher`，AAD 换成 `"uTerm device-group relay frame v1"`）：随机数 = 4 字节 0 ‖ 8 字节大端帧序号，每个方向自己数、不随帧发。明文 = 1 字节类型（1 最后一片、4 还有下一片、2 证明、3 探活、5 `bye`）+ 内容。解不开（被改、重放、乱序、丢帧）立刻结束这条线路。
4. M 回 reply 后马上发自己的证明帧（内容 = SHA-256(`"uTerm device-group relay proof v1"` ‖ SHA-256(抄本))，m2c 第 0 帧）；C 核对过才发自己的（c2m 第 0 帧）并算建立；M 核对过 C 的才算建立、才收业务帧。握手 10 秒不完就放弃。
5. 建立之后 30 秒没发过东西发一个探活帧，90 秒什么都没收到就断开。正常收线路（本机关、被换下）先发 `bye`，对端不用等超时。

### 分片

中继一帧（整条 JSON）最长 64 KiB，同步层一条消息最大 48 KiB，base64 之后放不进。线路把一条消息切成每片 30 KiB 明文（`RemoteGroupRelayHandshake.fragmentSize`），前面的片类型是「还有」，收齐了才交给同步层：对同步层仍是一帧进一帧出。一片的 `signal` 编码后约 42 KiB。拼起来最多 256 KiB（和局域网一帧的上限相同），超了断开。缺片、乱序片在密封那一层就过不了（帧序号对不上），不会交出半条消息。

### 下线与重连

- 拨号方发信令收到 `undeliverable`（对方信箱不在线）：结束这条线路，把这个信箱记成不在线，等下一次 `list`。
- 拨号方的 `client` 连接断了：它上面的线路全部作废。信箱那头不会被告知，靠 90 秒空闲超时收掉；对方从新连接重拨时信箱那头同一台对端的新线路建立后，按「同一方拨的留新的」换掉旧的。
- 信箱重连（换网络、被中继踢掉）：拨号方还在旧链路号上发的密封帧，信箱不认识这个链路号，回一个 `reset`（每个链路号只回一次）；拨号方收到就结束、1 秒后在同一个 session 上重拨。`reset` 不加密：能往这个 session 里写的只有中继本身和信箱（session 归拨号的那条连接，别的成员冒用 session 中继直接丢），它们本来就能掐断。
- 拨不通（握手超时、被拒）按 1 秒起翻倍、最多 30 秒重试这一台；连上过、被对方正常关掉的（`bye`）也按退避，免得对方还连着局域网时每秒拨一次。

### 挑线路

- 同步层按 `RemoteGroupLinkKind.priority`（局域网 2 > 中继 1）挑：已有局域网时新来的中继线路直接关掉；局域网后到时换成局域网、关掉中继那条；同一种线路新的替旧的（各自的服务先挑好）。换线路时新线路沿用旧线路上「对端有什么」的账，推送不中断；新线路照常先对一次 `sync`，不会把全部记录重推一遍。
- 中继服务拨号前问同步层（`hasPreferredLink`）：和这台对端连着局域网就不拨，信箱也不回它的 hello。局域网断了，同步层的 `onLinkClosed` 叫中继服务马上对这台补拨（信箱在线时），不等下一拍。
- 两台互相拨通了两条时：和局域网同一条规则，设备 ID 小的那台拨的那条优先，同一方拨的留新的；两边各自按这条规则挑，结果一样，丢掉的那条发 `bye`。为了少拨一次，ID 小的那台看到对方在线就拨，大的那台看到对方在线 5 秒还没有线路才拨。
- 名册里同一个设备 ID 有几条 `device`（钥匙串圈里的人能写）时，新的先试，拨不通轮着换下一条。

### 起停

跟着 `RemoteGroupFastChannel`：`live` 在测试宿主、没有远控私钥、名册不是叠加层时返回 nil，否则局域网和中继一起开。Mac 上 App 开着就开，iOS 只在前台（退后台 `RemoteDeviceGroupService.stop()` 收掉，信箱随之下线；回前台重建，投递那条连上马上 `list`）。全在 App 进程里，远控进程不碰。

### 日志

`设备组：快通道用默认中继 host:port` / `…没有默认中继，中继这条不开` / `…默认中继只有成员证书，注册不了信箱，中继这条不开`；`设备组：信箱已注册到中继 host:port（中继 1.3.0）`；`设备组：中继信箱注册失败：中继已满…，300 秒后再试` / `…绑着别的钥匙…`；`设备组：信箱被顶替…`；`设备组：和「X」的中继线路已连上（本机拨出 / 对方拨入）`、`…断开：原因`；连接断开、没回音各一行 info；拨不通、名册外的拨号是 debug。收到的记录沿用同步层那行 `设备组：经中继收到「X」的 admit，写入后 N 秒`。成员私钥、信箱钥匙从不进日志。

### 与 §7.4 不同、或 §7.4 没说的地方

- **信箱的 `box` 不是「HKDF(共享秘密, salt `uterm-group-sync-v1`)」一把长期的钥匙**：§7.4 写的是每条信令各自封、带时间与随机数防重放。现在照局域网那套做成一次握手：两边各出随机数派生会话密钥，之后按帧序号封。重放、乱序靠帧序号直接挡住，不用记见过的随机数、不用比钟；`uterm-group-sync-v1` 留在 info 的标签里。
- **hello 带两把公钥**：C 自己的（名册里同一个 ID 可能有几条，带上就不用逐条试）和它以为的 M 的（M 的公钥换过时 M 直接不回，C 拨不通后换下一条）。
- **reset**（§7.4 没有）：信箱重连后拨号方不用等 90 秒。
- **每台对端一个固定 session**（§7.4 没说）：中继的 `client` 连接最多 64 个 session、断开才清，每次重拨换新 session 用不了多久就满了，满了之后的信令中继静默丢弃（不回 `undeliverable`）。
- **信箱不回连着局域网的对端**、**被对端关掉的也退避**：局域网两头发现断开的时间不一样（最长 45 秒），这期间中继那边会来回拨；这两条把它压到退避的节奏。
- **网络一变就重连**（照 `RemoteRelayHostLink`）。

### 仍然不严的地方

- **信箱占中继的名额**：在线主机默认 64 台，开着 uTerm 的每台设备多占一个（Mac 若还开着远控的公网接入就是两个），满了信箱注册回 `full`、5 分钟后再试，这期间这台设备只走局域网和钥匙串；更糟的是信箱先占满了名额，后来的 Mac 远控注册不上。主机绑定（1024 个）也各占一个、不在线也不释放：iPhone 删了重装设备 ID 会变，旧信箱 ID 的绑定一直留着，要在中继上 `uterm-relay forget`。
- **中继上别的成员能看到什么**：持成员密钥的成员 `list` 看得到所有信箱 ID 和它们什么时候在线（持证书的只看得到自己那台主机）；从信箱 ID 反推不出设备 ID，但知道设备 ID 的人（名册在 iCloud 钥匙串里，钥匙串圈里的人都知道）算得出谁的信箱在不在线。中继本身看得到哪个 `client` 连接往哪个信箱发了多少、什么时候，`from` 里是明文的设备 ID。内容看不到。
- **`superseded`**：同一台设备的两个进程（开发构建与正式版共用设备 ID 与钥匙串）都开着时会互相顶，被顶的一方 5 分钟起翻倍再试；这期间别的设备往这个信箱投的东西只到另一个进程。别的成员顶不了：信箱 ID 绑着只有本机有的钥匙。信箱钥匙丢了（钥匙串被清）而设备 ID 还在时注册回 `hostKey`，要在中继上 `forget` 那个信箱 ID（日志里有）。
- **拨号方断线后信箱那头最多 90 秒才收掉**：中继不告诉主机拨号方走了。期间对方要是从别的连接重拨，新线路一建立就换掉旧的；不重拨的只是多占一点内存。
- **没有前向保密**：和局域网一样，会话密钥由两把长期 X25519 钥匙和两个随机数派生。
- **名册外的拨号要读一次钥匙串**：信箱每收到一个 hello 读一次 `baseDevices()`，同时在握手的最多 16 条；能往信箱发 hello 的只有持成员密钥的中继成员。
- **投递那条每 15 秒读一次钥匙串名册**（`list` 回来时），名册变了最多 15 秒后才拨新设备。
- **没在真机上验**：手机走蜂窝、Wi-Fi ↔ 蜂窝切换、App 退后台再回来、Mac 睡醒，以及和远控的中继注册同时跑，都要在装好的包上试；日志里比「经中继收到 … 写入后 N 秒」和钥匙串那一行。

### 重拨风暴与认证误判（真机，2026-11-17 修）

**现象**：MacBook 与 mini 只走中继，mini 的 ID 小、由它拨出。MacBook 的信箱连接重连后，MacBook 10 秒里往 mini 的信箱拨了约 170 次（每 60 毫秒一轮「已连上（本机拨出）→ 线路断了」），直到 mini 往旧线路上发东西、收到 reset 才停。另一次 MacBook 在睡眠中短暂唤醒（网络没好）时注册信箱，日志说「中继没有接受这份配置…需要重新导入，300 秒后再试」。

**原因**（三处叠在一起）：
1. 去重只看「谁拨的」：mini 手里那条自己拨出的线路在 MacBook 的信箱重连后已经死了，但 mini 没往上发东西、不知道，于是按「ID 小的拨的优先」把 MacBook 新拨进来的关掉（`bye`）。
2. 同步层的 `onLinkClosed` 对中继线路自己断开也报，中继服务的 `linkLost` 把这台对端的 `retryAt` 清零、马上再拨，盖掉了 `ended` 刚排好的退避；`established` 每次连上又把退避清零。所以一轮只受握手往返时间限制。
3. 「发出请求后对端一言不发就断开」在协议里是认证不过的样子，网络没好时也是这样，一律当成配置被拒、5 分钟后再试。

**改法**：
1. 对方拨进来本身说明它手里已经没有线路（有活的它就不会拨）。本机拨出、建成超过 `raceWindow`（5 秒）的那条，被对方新拨进来的换下；窗口之内才是两边同时拨的竞争，照旧按 ID 规则（`RemoteGroupRelayService.prefers`）。局域网有同样的漏洞（旧连接已死、对方新连进来的被去重规则关掉，按每秒一次重连），同样改了（`RemoteGroupLANService.prefers` + `activeSince`）。
2. `linkLost` 只对局域网断开补拨，中继线路断开交给 `ended` 的退避；连上时不再清零退避，线路活过 `stableAfter`（10 秒）才清零，比这短就断的（被去重、`bye`、reset、`undeliverable`）翻倍（1 秒起、最多 30 秒）；同一台对端两次拨号至少隔 `minDialInterval`（1 秒），任何原因都绕不过。局域网的退避同样改成活过 10 秒才清零。
3. 本进程里认证通过过的配置（relayID + 成员密钥的摘要，只在内存）之后再遇到静默断开，按普通网络失败退避，日志写「中继在认证之前断开了（这份配置之前连上过，多半是网络还没好）」；从没通过过的照旧 5 分钟起。两条控制连接共用这份记录。

**仍然不严**：认证通过的记录只在内存，App 刚启动（还没连上过）就碰上网络没好时仍按被拒处理、5 分钟后再试。局域网的去重改动只经现有用例回归，没有单独复现「一头连接已死」的用例（要造一条只有一头知道断了的 TCP）。

### 测试

- `RemoteGroupRelayLinkTests`（15，两条 `RemoteGroupRelaySession` 之间一根内存管子，可以截、丢、换序、重放、改帧）：信箱 ID 稳定、不是设备 ID、两千个不撞、版本位 8、固定向量；信箱钥匙存得住、和远控那把不同；`box` 编解码与各种坏长度、坏版本、坏种类；握手后双向收发，100 KiB 的消息分片、每个 `box` 塞得进中继一帧；恰好一片、三片、超长、超长后清空；缺一片、两片换序都断开且不交出半条；名册外、名册里公钥不对、拨号方拿的是信箱主人的旧公钥，信箱一个字都不回；报了名册里的 ID 和公钥但没有私钥，过不了证明帧、硬塞的密文也进不去；session、方向、任一端设备 ID 换了解不开，局域网的 AAD 解不开，小阶点拒掉；重放、换序、改一个字节都断开（之前那条照收，同步层收到断开）；录下的 hello + 证明帧再放一遍进不去；别的链路号的 reset 不理、这条的 reset 断开；握手超时、30 秒探活、90 秒空闲断开、`bye` 让对端马上断开；`activate` 之前收到的帧按序留着；两条之间按「ID 小的拨的优先、同一方拨的留新的」挑。
- `RemoteGroupRelayServiceTests`（13，内存假中继 `FakeGroupRelay`：`host` 注册含钥匙绑定 / 容量 / 顶替，`client` 的 `list` / `signal` 转发，session 归属与每条连接 64 个，`undeliverable`，单帧 64 KiB 超了断开发送方；夹具在 `RemoteGroupRelaySupport.swift`）：两台只靠中继收敛、改动一推就到、只留 ID 小的拨的一条；只有中继的 A 与只有局域网的 C 经两条都有的 B 转手记录与删除；三台两两连上收敛；局域网在时中继注册了也不拨、局域网断了马上回落到中继、局域网再来换回去并关掉中继那条且不重拨、换线路不重推对端已有的；两边同时拨只留一条且稳住；对端不告而别后清理、之后不再拨通；信箱忘掉线路后拨号方被 reset、马上重拨连上；中继踢掉信箱后两边都恢复；被顶替不马上重连；中继满了、信箱 ID 绑着别的钥匙都不每秒重试；没有默认中继、只有成员证书时不开，配置来了跟上、没了收掉；40 条大记录分片后每帧不超过 64 KiB（最大的一帧超过 32 KiB，确实要分片）；两台 `RemoteDeviceGroup`（钥匙串互不同步、只预先放好双方的 `device`）只靠中继走完加入 → 输码 → 进组 → 回执。
- `RemoteGroupRelayMailboxEndToEndTests`（3，经真实 `uterm-relay`，`make test-relay-e2e` 起的那台，没有就跳过）：两台各注册信箱（`list` 里是信箱 ID、不是设备 ID）、互相投递、30 条三四 KiB 的记录分片后到齐、只留一条、之后的改动推到，一台不告而别后另一台清理、它的信箱下线；正常退出时对端马上知道（空闲超时设成 60 秒）；同一个信箱 ID 再注册一次，先来的被顶替、不马上重连，换一把钥匙中继回 `hostKey`。
- 修重拨风暴时加的（`RemoteGroupRelayServiceTests` 现 17 条、`RemoteGroupRelayLinkTests` 现 16 条）：对方的线路死了再拨进来，第一次拨号就被接受、旧线路被换下、之后不再拨、全程 hello 个位数（把新规则关掉时这条用例拨了 9 次都进不去）；对端每次握好手就 `bye` 时 4.5 秒里只拨 2–4 次；配置连上过之后的静默断开按普通退避几百毫秒内重新注册上，从没连上过的两条连接各只试一次；`prefers` 对建成已久与刚建成的本机线路分别给出「换新」和「按 ID 规则」。
- 上面几个类各连跑 5 遍（`-test-iterations 5 -run-tests-until-failure`）都过；§16 的几个类和 `RemoteRelay*`、`DefaultsKeyLintTests`、`RemoteLocalStateLintTests` 照旧全过；`make test-relay-e2e`（真实中继）27 个全过。

## 18. 资历规则落地

2026-11-17，分支 `claude/sibling-confirm-popup`。补 §15「攻击者抢先撤销」：同组撤销（消息 52）按设备加到这台 Mac 的先后判断谁能撤谁、撤上游时留谁。XPC 协议没动；消息 53 只加了一个可选字段和一个结果码；组里的 Mac 撤被移除的组员（D，`handleGroupDrop`）、`groupAddController`、同组的判断（`family`）、不拉黑、连带不解除拉黑都不变。

### 文件

- `uTerm/Core/Remote/RemoteVouch.swift`：`RemoteSiblingRevokeResult.Outcome.notSenior`（`not-senior`）、`requesterRevoked`；`RemoteVouchPolicy.decideRevoke` 多一个参数 `trusted`，加资历判断；新 `addedAt` / `isAdded(_:before:addedAt:)` / `ancestors` / `survivor`。`cascade`、`reanchor` 没改。
- `RemoteHostServer.handleSiblingRevoke`：挑留下的那台，回执带 `requesterRevoked`，下一拍按它撤；`not-senior` 回给人看的原因。
- 组员一侧：`RemoteGroupLocalStore.swift` 的 `RemoteGroupPausedHost`、状态里的 `pausedHosts`（自己写的解码里按缺了是空的取）；`RemoteDeviceGroup+Revoke.swift` 的 `finishRevoke`（新的三种处理）、`pauseHost`、`resumePausedHosts`；`RemoteDeviceGroup+Hosts.swift` 里停着的 Mac 不排活、显示「开通中」、读名册放快。

### 规则（被控端）

同一组里（`family` 相同，照旧先判），请求者 R 撤 T：

- 允许：T 就是 R；T 是 R 的上游（`ancestors`：顺着 `vouchedBy` 往上，只走此刻还被信任的设备，碰到这台 Mac 自己、手动配对的、挂在自己身上的、环就停）；T 比 R 晚加到这台 Mac。上游再早也能撤，这是「上游」的意思：丢了的往往正是担保你的那台。
- 否则回 `not-senior`，什么都不改。
- 撤的范围：`cascade(from: T, keeping: S)`。S（`survivor`）= R 在 T 那一串里（T 是 R 的上游）时，那一串里（不含 T）最早加到这台 Mac 的那台；R 不在那一串里（T 是 R 担保的、或在别的分支）、撤的是自己时，没有 S，整串撤掉。S 连同它担保的留下，S 的来路照 `reanchor` 改挂（T 的担保者还在就挂过去，否则挂自己）。
- R 不在 S 那一支里时它自己也在撤掉之列：回执（`revoked`，`requesterRevoked: true`）先发出去，下一拍才删信任、断开（和原来撤自己是同一个顺序）。下一拍之间被重新配对、换了钥匙的照旧不撤；S 在回执时算定，下一拍按它重新算一遍要撤的设备（这一拍里信任表变了的话，回执里的 `requesterRevoked` 可能和实际不一致，很少见）。

### 时间取哪

- 用信任表里的 `RemotePeer.pairedAt`，不用担保记录的 `vouchedAt`，也不新加字段。核过的写入点：手动配对 / 凭邀请（`RemoteHostConnection.newPeer`）、被担保与按设备组记下（`handleVouch`）都写 `Date()`，是 Mac 自己的钟、记下这把钥匙那一刻；改名（`rename`）、认出来时更新名字机型（`rememberRecognized`）、发中继证书（`relayConfig(forPeer:)`）都原样带着它；`reanchor` 只改担保记录，不碰信任表。被担保的设备 `pairedAt` 和 `vouchedAt` 是同一次调用写的，手动配对的没有担保记录、只有 `pairedAt`，所以一个字段两种设备都有。
- 不用 `vouchedAt` 的原因：在 Mac 上手动重新配对一台以前被担保过的设备时，审批不清它的担保记录（§15），`vouchedAt` 还是旧的，`pairedAt` 是新的；按「加到这台 Mac」算应当是新的。
- `pairedAt` 从信任表的第一版起就是非可选字段，旧记录没有缺的。旧远控进程重写信任表也不丢它（只丢它不认识的新字段）。请求里不带任何时间。

### 时间缺失、相同

- 比较的是（`pairedAt`，设备 ID 的字符串）这一对：时间早的算早；时间相同按设备 ID 字符串排，小的算早。任意两台都分得出先后，两个方向的结论一致。
- 缺时间（`addedAt` 里没有它：只有不在信任表里的设备会这样）当最早（`distantPast`）。在 `decideRevoke` 里 T 一定在信任表里（先判了 `not-trusted`），R 是刚认证过的连接，正常也在；这条只是让纯函数对任何输入都有确定的结果。

### 改挂、重新加回来

- 改挂不改资历：`pairedAt` 不动，`vouchedAt` 也不动（App 照旧不为改挂发通知）。改挂会改上游：挂在自己身上的 S 之后没有上游，挂到 T 的担保者 V 下面的，V 和 V 的上游成了它的上游。
- 被连带撤掉、又被重新担保回来的设备是新加的：`handleVouch` 写新的 `pairedAt`，比没被撤的都晚；它的上游换成替它重新开通的那台。手动重新配对同理。
- 能不能被拿来改资历：设备变早只能靠 Mac 的钟往回拨（不是主控端能做的）；变晚要先被撤掉。攻击者能撤的设备（自己的上游、比自己晚的）里，比它晚的变得更晚，先后关系不变；它的上游被撤后由 S 重新开通，重新开通的设备挂到 S 下面，同样只会更晚。所以攻击者没法让自己排到原有的组员前面。反过来，**被重新开通的一方会把开通它的那台当上游**，见下面「仍然不严」第二条。

### 结果码与线格式（消息 53）

- `not-senior`：新结果码。老的主控端按 `Outcome(rawValue:)` 认不出（`kind == nil`），落到 `finishRevoke` 已有的「认不出的结果，6 小时后再问」，不写成做完、不刷日志（每 6 小时一条）。
- `requesterRevoked: Bool?`：新 Mac 在 `revoked` 时带 true / false，别的结果不带；老 Mac 不带（那时请求者总是留下）。老的主控端不认这个键，照旧按 `revoked` 处理（见下面「仍然不严」）。
- `not-senior` 带给人看的原因：「它比本机更早加入这台 Mac，需由更早加入的组员或在 Mac 上撤销」（新文案，在 `RemoteHostServer.handleSiblingRevoke`）。

### 组员一侧

- **回执说本机也被撤了**（`revoked` + `requesterRevoked == true`）：这条撤销照常记成这台 Mac 做完；不设「重新算起」（本机已经不被信任，问不了）；记一条 `RemoteGroupPausedHost`（存在本机状态里，App 重开后还在）：Mac 的 ID、那一刻信任表里这台 Mac 的记下时间、那一刻名册里写给本机、关于这台 Mac 的结果的签名。停着的时候：这台 Mac 上开通、撤销都不排（连它会让 Mac 弹配对审批框）；「还没通的 Mac」里显示它「开通中」（之前那些说能用的结果不算）；读名册照「刚进组」放快 10 分钟。解除：名册里出现一条我认的组员签的、能用的、签名不在那份名单里的结果（别的组员替本机重新开通了，不比钟）；你在本机重新配对过这台 Mac（记下时间变了）；本机不再配对它。
- **谁来重新开通**：留下的 S 和别的还被信任的组员不知道 R 撤过什么，它们随后各自来撤同一台被移除的设备时，Mac 已经不认它，回 `not-trusted`。所以**`not-trusted` 现在也设「重新算起」**（§15 原来只在 `revoked` 时设）：分不清是「Mac 本来就不认识它」还是「别的组员刚撤过、连带了谁（可能连发请求的那台自己）」，一律把这台 Mac 上的组员再问一遍，还被信任的回 `already-trusted`，被撤掉的重新记下。R 停着、不去问，只等别人。`not-in-family` 照旧不补问。
- **`not-senior`**：6 小时后再问（同不允许、太旧），只记在这台 Mac 上，别的 Mac 的进度、这台 Mac 上别的撤销与开通都不受影响；「已移除的设备」里这台 Mac 一直算没撤，直到更早的组员撤掉它、本机再问时回 `not-trusted`。例外：**这台 Mac 本身是组员**时算做完——它每轮自己撤掉被移除的组员（§7.3 D），设备组记下的组员同属一组、按记下的先后排，较晚的组员撤较早的必然 `not-senior`，不这样的话「已移除的设备」会白挂 6 小时。

### 与 brief 不同、或 brief 没说的地方

- 时间用 `pairedAt`，不用 `vouchedAt`，也没加「首次加到这台 Mac 的时间」字段（理由见上）。
- `not-trusted` 也触发「重新算起」：brief 只要求确认现有机制对请求者成立；核下来不成立（请求者撤了之后，留下的那台撤同一台时拿到的是 `not-trusted`，原来不补问，请求者就一直被晾着），所以改了。
- 本机被撤的那台 Mac 停下、显示「开通中」，存进本机状态。brief 只说「不能把旧开通结果当成有效」，这里落成：开通、撤销都不再去连它，界面显示开通中；旧结果不删（名册里是别人签的）。
- 组员 Mac 回的 `not-senior` 算做完（见上）。

### 仍然不严的地方

这些边角为什么补不完、往后怎么收敛，见 `docs/remote-group-trust-research.md`（2026-11-17 的研究，没改代码）。

- **被偷的设备自己**：被偷的 X 在被移除之前照样是被信任的组员，资历是它被偷之前就有的。它能撤比它晚的组员、它的上游，撤上游时留下的是那一串里最早的（可能就是它自己）。这和原来一样（原来它能撤同组的任何一台），资历规则只挡住「它被偷之后才加的设备」。被偷之前攻击者的设备就已在组里、比正常组员早，同样挡不住。
- **被正常组员担保过的攻击者设备能撤那台正常组员**：被偷的 X 把攻击者的 Y 加进名册，正常的 M 照 G2 替 Y 向这台 Mac 担保，Y 的上游就是 M，Y 可以撤 M（上游一律允许）；留下的是 M 那一串里最早的，Y 若是 M 在这台 Mac 上担保的第一台就是 Y 自己。比原来窄（原来 Y 能撤同组的任何一台），但超出了 X 自己能做的（M 可能比 X 早、又不是 X 的上游）。被重新开通的设备同理会把开通它的那台当上游。要挡住它，Mac 得分清「担保你的那台丢了」和「你在撤担保你的那台」，现在的信息分不出来；路子还是让 Mac 认设备组签名的 `remove`。
- **撤较早的、丢了的组员要靠更早的组员**：X（手动配对）先后担保了 Y、M，Y 丢了：M 撤 Y 回 `not-senior`，只有 X（Y 的上游）或比 Y 早的设备、或 Mac 主人能撤。X 不在组里、或也丢了时，要到 Mac 上撤。「已移除的设备」里那台 Mac 会一直显示没撤（每 6 小时问一次）。
- **新旧版本混用**：老的主控端不认 `requesterRevoked`，被一起撤了也照「撤成功」去补问、连这台 Mac，Mac 会弹配对审批框（审批了就是手动重新配对，也算一种恢复）；老的主控端拿到 `not-trusted` 不补问，被撤掉的请求者要等别的新版组员。老 Mac 照旧留下请求者，没有资历规则。
- **补问的量**：每台组员撤一台被移除的设备时都会补问一遍（`revoked`、`not-trusted`），K 台组员在一台 Mac 上大约问 K×(K−1) 次、写同样多条结果；Mac 本来就不认识被移除的设备时也一样。移除很少发生，没再细分（要细分得让 Mac 记住「刚被设备组撤过」，远控进程重启就忘）。
- **留下的那台不是会补问的组员**：S 是这台 Mac 上一台不在设备组里的设备（以前「已配对设备担保」加的），或者一直不上线、它的移除记录里没有这台 Mac，那就要等别的还被信任的组员来撤、回 `not-trusted` 才补问；一个都没有时被撤掉的正常组员只能到 Mac 上重新配对。
- **手动重新配对会让设备变晚**：在 Mac 上重新配对（审批）一台设备，它的 `pairedAt` 是新的，排到组员后面；担保记录不清（§15），它照旧在原来那一组里。
- **Mac 的钟往回拨**：之后加的设备会排到前面。
- 「重新算起」仍只在内存（§15）。停着的 Mac 存在本机状态里，但「签名不在那份名单里」只认新签名：留下的那台签的新结果若恰好和旧的一字不差（同一签名者、同一时刻）会认不出，实际不会发生（签名时间不同）。

### 测试

- `RemoteVouchTests`（34，改 2 加 5）：
  - 改：`test_revoke_policy_only_within_the_same_group_and_the_same_key`（`decideRevoke` 多了 `trusted`，给每台设好时间；结论不变）；原 `test_attacker_revoking_first_strands_a_sibling_when_the_revoked_device_was_the_only_one_paired` 改成 `test_attacker_revoking_first_takes_itself_out_and_the_earliest_sibling_stays`：Y（还担保了 Z）抢先撤 X → 回执 `requesterRevoked`，X、Y、Z 撤掉不拉黑，M 留下、挂自己、组号不变、`pairedAt` 不变，Y 再连要审批；M 撤 X 回 `not-trusted`，替 M2 开通成功。`test_attacker_revoking_first_keeps_itself_only_until_an_ancestor_revokes_it` 只改了注释（那种情况资历规则下结果不变）。
  - 加：`test_seniority_policy_upstream_or_later_and_the_earliest_of_the_line_survives`（纯规则：上游再早也能撤、比自己晚的别的分支能撤、比自己早的不是上游的不能；撤上游留那一串最早的、请求者不在那一串里与撤自己没有要留的；时间缺失当最早、时间相同按设备 ID、两个方向一致）；`test_not_senior_result_reads_as_unknown_on_an_old_controller_and_receipt_flag_is_optional`；`test_later_sibling_revoking_the_shared_voucher_is_revoked_too_and_re_added_devices_count_as_new`（X 依次担保 M1、M2、M3，M3 撤 X → 自己被撤、M1 留下改挂、`vouchedAt` / `pairedAt` 不变；M1 先后替 M3、M2 重新开通，M2 现在比 M3 晚，撤 M3 回 `not-senior`，M3 撤 M2 成功）；`test_device_cannot_revoke_an_earlier_sibling_that_is_not_upstream_but_the_earlier_one_can`（`not-senior` 时信任表、来路、连接都不变）；`test_revoking_your_upstream_is_always_allowed_and_revoking_yourself_still_works`（A → B → C，C 撤祖父辈 A，留 B、C 跟着 B 留下；C 撤自己，回执说它被撤了）。
- `RemoteDeviceGroupRevokeTests`（21，改 1 加 3）：
  - 改：原 `test_member_re_asks_the_mac_once_after_a_successful_revoke_and_not_after_a_no_op` 改成 `…_after_a_revoke_or_a_not_trusted_reply_but_not_after_not_in_family`：`not-trusted` 之后现在补问一遍（原来断言不补问），`not-in-family` 不补问（新加的一段）。
  - 加：被一起撤了之后这台 Mac 记成撤完、显示开通中、不补问、新组员也不替问、不再撤别的，留下的 A 撤同一台回 `not-trusted` 后补问、替它重新开通，它读到新结果恢复、状态清空；在本机重新配对过就解除、存在本机状态里、老状态没有这个字段照样解得开；`not-senior` 6 小时后再问、别的 Mac 照常、组员 Mac 算做完。
- `RemoteGroupHostAccessTests`（7，加 1）：`test_end_to_end_later_member_revoking_its_upstream_is_revoked_and_the_earliest_re_opens_it`：真服务端、三台真 `RemoteDeviceGroup` 走真加入；X 手动配对、先后替 M1、M2 开通；M2 移除 X 并去撤 → X、M2 不再被信任，M1 留下挂自己、资历不变，M2 显示开通中、状态里停着这台 Mac；M1 去撤拿到 `not-trusted`、补问、替 M2 重新开通（全程 Mac 没弹审批框）；M2 恢复、不经审批连上。
- `RemoteGroupFakeHosts.RevokeReply.outcome` 多了 `requesterRevoked`（默认 nil）。
- 用变异核过：`survivor` 改回「留请求者」，`RemoteVouchTests` 的纯规则、抢先撤、较晚组员撤、撤上游 4 条红，`RemoteGroupHostAccessTests` 的端到端红；`not-trusted` 改回不补问，`RemoteDeviceGroupRevokeTests` 的补问与「等别的组员重新开通」两条红。

## 19. 操作前验证本人、提示 Mac 进组

2026-11-17，分支 `claude/sibling-confirm-popup`。做的是 `docs/remote-group-trust-research.md` 第 5 节的第 1、2 步（第 4 节的 D、E）。只动了主控端一侧的设备组服务与两端界面；被控端规则（`RemoteVouch.swift`、`handleVouch` / `handleSiblingRevoke`）、XPC 协议、远控进程、中继都没碰，新文件也没进远控进程的编译清单。

### 文件

- `uTerm/Features/Remote/RemoteGroupOwnerCheck.swift`（新，两端共享）：验证本人的规则。注入 `BiometricAuthenticator` 和时钟，`confirm(_ action) async -> Bool`。
- `RemoteDeviceGroupService.swift`：持有一个 `RemoteGroupOwnerCheck`（init 可注入）；新 `remove(_ ids:) async -> Bool`、`leave() async -> Bool`；`submit(_:for:)` 改成 `async`，先验证再核对。
- `RemoteDeviceGroup.swift` / `+Hosts.swift`：新 `pairedHostIDs`（每轮 `syncHosts` 按 `hosts.pairedHosts()` 刷新，只在变了时写）。模型上的 `remove` / `leave` / `submitCode` 没加验证、签名不变。
- `RemoteDeviceGroupCopy.swift`：验证框上的说明、两句提示、`outsideSubtitle` / `isPairedMacOutside`；`RemoteDeviceGroup.suggestsJoiningLocalMac`。
- 界面：Mac `RemoteMyDevicesGroup`（移除单子、离开、提示）、`RemoteDeviceGroupPrompt`（输码面板）；iOS `RemoteMyDevicesScreen`、`RemoteGroupJoinHandler`。移除单子（两端）的回调从 `onDone([UUID]?)` 改成 `onCancel` + `onRemove([UUID]) async`。

### 验证本人

要验证的三个操作，都在服务层：

| 操作 | 入口 | 系统验证框上的说明 |
| --- | --- | --- |
| 移除组员（含勾着的连带设备，一次移除验一次） | `service.remove(plan.ids)` | 「移除「X」」，带连带时「移除「X」等 N 台设备」 |
| 组员一侧输满 6 位验证码 | `service.submit(code, for:)` | 「将「X」加入设备组」 |
| 离开设备组 | `service.leave()` | 「离开设备组」 |

不验证：本机点「加入」显示验证码（要别的组员输码才进得来，那一头验）、取消、拒绝、关闭、打开页面。

规则（`RemoteGroupOwnerCheck`）：

- 策略 `.deviceOwnerAuthentication`：iOS 面容 ID / 触控 ID，不行退密码；Mac 触控 ID，不行退登录密码。
- `.success`：放行，记下时间；之后 5 分钟（`gracePeriod`）内同一台设备上不再验。时间只在内存，App 重开后要重新验；钟往回拨（时间差为负）不算刚验过。
- `.unavailable`（没设密码、Mac 上没法验证）：放行，记一行日志，不算验过（下次照样问）。没有可验证的东西，不能把人锁在外面。
- `.canceled` / `.failed` / `.biometryLockout`：不放行，操作不做。
- 同时来两次（连点）：第二次等第一次的结果；第一次过了，第二次在 5 分钟内直接放行，不弹第二个框。
- 测试宿主（`RemoteLocalState.isIsolated`）里默认不验、直接放行（`defaultAuthenticator()` 为 nil）；用例注入假的 authenticator 测规则。
- 应用锁刚解锁**不算**一次：`AppLockModel` 没有记解锁时间，没为此改它。

验证没过时界面回到操作前：

- 移除：单子不关，可以再点「移除」或「取消」；验证通过、移除做了才关。等验证时「移除」不再响应。
- 离开：确认框照常收起，什么都没发生。
- 输码：输满 6 位后照旧等 0.18 秒让最后一位显示出来，然后验证、核对。验证没过弹窗 / 单子不关，输入清空，重输即再验一次；格式不对的不弹验证框。等验证时再输满、按回车都不再提交。
- Mac 的输码面板是 `.nonactivatingPanel`：系统验证框是另一个进程的窗口，关掉后 key 窗口不一定回到面板（App 不在前台时会回到原来那个 App）。验证结束后（过没过都）`RemoteDeviceGroupPrompt.refocus()` 调 `panel.makeKey()`，面板不激活 App，输码格子本来就是它的第一响应者，接着打字就行。面板本身一直在（只有 `pendingRequest` 变了才关）。

界面别绕过服务：`RemoteGroupOwnerCheckLintTests` 扫这四个界面文件，接收者不是 `service` 的 `.remove(`、`.leave()`、`.submitCode(` 一律判红。

### 提示 Mac 进组

两处，各一句，不弹窗、不用警示色：

- **Mac 上**（`suggestsJoiningLocalMac`）：本机是 Mac、交了被控端且 `acceptsGroupControllers`（开着被控和「允许已配对的设备开通主人的其它设备」）、没进组、没被移出、没在加入（显示着验证码或失败原因时不加）、名册里有别的设备时，「加入」那一行上方一条说明：「本机加入设备组后，可远程控制本机的设备由设备组统一管理，移除设备立即生效。」iOS 不交被控端，恒为 false。
- **组员设备上**（两端）：「未加入的设备」里是 Mac、且 id 在本机的 `pairedHostIDs` 里的那一行，副标题在机型后面加「加入后，组内设备无需单独配对即可控制它」。iOS 那一行开 `wraps: true, subMono: false`。

### 与 brief 不同、或 brief 没说的地方

- Mac 上的提示条件用 `acceptsGroupControllers`，不只看「开着被控」：关着担保时这台 Mac 进了组也不按名单记主控端（`syncLocalHost` 的守卫），那句话不成立。
- 被移出（`isSelfRemoved`）时不提：那时已有「本机已被移出设备组，需重新加入」。
- 移除验证没过时单子留着，而不是像原来那样先关单子再移除。
- 输码不预先核请求状态，只核格式：请求是否还开着、次数用完没有仍由 `submitCode` 判（验证之后），和原来一样。

### 测试

新文件 `uTermTests/Core/Remote/RemoteGroupOwnerCheckTests.swift`（四个类）：

- `RemoteGroupOwnerCheckTests`（6）：通过后 5 分钟内免验、过了再验、钟往回拨再验，策略是 `.deviceOwnerAuthentication`；不可用放行但不算验过；取消 / 失败 / 锁定不放行，没过之后再试能过；测试宿主默认放行、不弹框；同时来两次只弹一个框；四种说明的文案。
- `RemoteDeviceGroupServiceOwnerCheckTests`（3）：注入「总是取消」时 `remove` / `leave` / `submit` 都不改名单、名册里没有新的 `remove` / `admit` / `answer`、请求仍是「等输码」且不算一次输码，格式不对的不弹框；注入「成功」时照常生效，输码那次验过后 5 分钟内移除、离开不再验；一次移除带连带设备只验一次（说明是「移除「X」等 2 台设备」，签了 2 条移除）。
- `RemoteGroupOwnerCheckLintTests`（2）：正则自测（抓 `model?.remove(`、`model.leave()`、`service.model?.submitCode(`，放过 `service.*` 与注释），四个界面文件扫描为空。
- `RemoteDeviceGroupJoinHintTests`（3）：Mac 提示的出现 / 不出现（不开被控或不允许担保、没交被控端、正在加入、不是 Mac、名册里没别的设备、进了组、被移出）；「未加入的设备」副标题只给本机配对过的 Mac 加那句；模型按 `hosts.pairedHosts()` 刷新 `pairedHostIDs`、不再配对就清掉。
- 改：`RemoteDeviceGroupServiceTests` 三处 `submit` 改成 `await`；`SettingsPageSnapshotTests.testRenderMyDevicesGroup` 加 `my-devices-solo-hint`（Mac 提示）、`my-devices-outside-paired-mac`（配对过的 Mac 一行），移除单子换新的回调；iOS `RemoteMyDevicesSnapshotTests` 加 `ios-my-devices-outside-paired-mac`（测试里自带一个只报配对、都不在线的 `RemoteGroupHostAccess`）。

写的时候踩到一处：最初在 `await task.value` 之后才清 `inFlight`，同时等着的第二处先醒时对着已完成、未清的任务同步空转，主线程卡死（同时来两次那条用例挂住）。改成在任务里落结果（记时间、清 `inFlight`）再返回。

### 没验证的地方

- 真机 / 真 Mac 上的系统验证框都没试过（XCTest 里不弹）：iOS 单子上面容 ID 框关掉后键盘与输码格子的焦点、Mac 浮动面板在 App 不在前台时验证框能不能弹出来、`makeKey()` 之后能不能直接打字，都是按 AppKit / LocalAuthentication 的行为推的。
- iOS 的 `NSFaceIDUsageDescription` 还在（`uTermMobile-Info.plist` 与 pbxproj 的 `INFOPLIST_KEY_NSFaceIDUsageDescription`），文案只说了解锁应用和远程解锁，没提设备组，没改。
- 拿到解锁设备的人若知道设备密码，验证照样能过；这一档挡的只是只会点界面的人。

## 20. 撤销进度卡住的两处

2026-11-17，分支 `claude/group-revoke-stale`。只动了主控端一侧的设备组与目录；被控端规则（`RemoteVouch.swift`、`RemoteHostServer`）、XPC 协议、远控进程、中继都没碰。

### 现象

user 的 MacBook 上，「我的设备」的「已移除的设备」一直挂着「iPhone Duo — 「我的 Mac mini」尚未撤销」，页脚「相关 Mac 上线后将自动撤销。」，mini 一直开着 uTerm。MacBook 的日志：Duo 自己点了「离开」（经局域网收到它的 `remove`），11 秒后又点了「加入」，核对通过、用同一把钥匙重新进组；之后没有一条「请「我的 Mac mini」撤销「iPhone Duo」」。当时 `utermctl macs` 报 mini `connected: false, onLocalNetwork: false`，也不在中继在线表里，而 MacBook 和 mini 的快通道一直经中继连着。

### 原因一：同一把钥匙重新进组，撤销进度没作废

`trackRevocations` 给本机认下的每条移除建一条撤销进度。设备离开后用同一把签名钥匙重新加入，名单里它又是组员（加入时间晚于那条移除），可移除记录不过期、进度也一直留着：

- 界面一直显示「尚未撤销」；
- 那台 Mac 被判定在线时，本机会真的去请 Mac 撤一台此刻的组员，再替它重新开通一遍；那台 Mac 不在组里时，`cascade` 还会连带撤掉由它担保的设备；
- 撤完之前，`scheduleHostWork` 的「同一个设备 ID 在这台 Mac 上还有没撤完的先不开通」把它挡着，重新进组的设备在这台 Mac 上一直开通不了。

### 原因二：有事要做时没人去问中继

`RemoteGroupHostAccess.vouchTargets()` 只取 `macs.filter(\.isOnline)`；`isOnline` = Bonjour 看得到或中继在线表里有。中继在线表是按需问的（为 iOS 省电，见 `RemoteMacDirectory.startRelayPolling` 的注释）：只有界面挂着 `keepLiveStatusFresh`、或有人读 `pairedMacs` 走 `refreshRelayHostsIfStale` 时才问。设备组在后台干活时两样都没有，只经中继够得着的 Mac 永远算不在线，撤销、开通都排不上，直到用户碰巧打开显示 Mac 列表的界面。之前几次真机走查都开着设置页，所以没暴露。

Mac 上的 Bonjour 浏览也一样只在打开远控窗口（或命令行 `utermctl macs`）时才开始，App 启动时不开；这次没改它（见下面「没改的」）。

### 改法

- **撤销作废**（`RemoteDeviceGroup+Revoke.swift` 的 `trackRevocations`）：每轮算进度时，这条移除对应的钥匙此刻是本机认的组员、它这次的加入时间晚于这条移除（`state.member(signingKey:)` 的 `admission.admittedAt > removedAt`），就把进度记成处理完：`hosts = []`、`finished` / `retryAfter` 清空，记一行日志。不加字段：之后的判断（`nextRevocation`、`settleRevocations`、「已移除的设备」、开通前的「先撤旧的」）都只看 `isSettled` / `isUnfinished`，作废和撤完不用区分。第一次读到移除时它就已经回来了（离线期间离开又加入），直接建成处理完的。
- **已经撤成功的不补救**：在某台 Mac 上撤成功（`revoked` / `not-trusted`）时 `finishRevoke` 照旧记下 `revalidateFrom`，本机把这台 Mac 上的组员再问一遍（§15、§18），重新进组的那台跟着被记回去；它离开时各组员已经删掉了自己替它签的 `grant`（`cleanUpGrants`），所以重新进组后本来就会被重新开通。
- **再次被移除**：`writeRemoval` 取的时间不早于它这次的加入时间，比作废的那条晚，`trackRevocations` 照「同一把钥匙后来又被移除一次」重建进度、从头撤。
- **在路上的那次请求**（`finishRevoke`）：结果回来时只改这台 Mac 上还没做完的那条进度，作废的（以及被更晚的移除换掉的）不写，不会被写活；什么都没变就不存、不多跑一轮。回执说本机也被一起撤了（`requesterRevoked`，§18）是 Mac 上已经发生的事，进度作废了也照样记下停着的 Mac（原来这种情况直接丢掉，本机之后会去连一台已经不认它的 Mac）。
- **有事要做就补问**（`RemoteDeviceGroup+Hosts.swift` 的 `scheduleHostWork`）：每台 Mac 下一件事（撤哪条、替谁开通）抽成一个函数，在线的照旧去做；配对过、此刻不算在线、这个函数又挑得出事来的 Mac 有一台，就调一次 `hosts.refreshReachability()`。「有事」和真去做用同一套判断：在问的、60 秒冷却里的、停着的（§18）、撤销在等重试的（太旧 6 小时、`not-senior`）、开通 6 小时内问过的，都不算。没事要做时不问。
- **目录那一侧**（`RemoteGroupHostAccess.swift`、`RemoteMacDirectory.swift`）：协议加 `refreshReachability()`，扩展里给默认空实现（测试假件不用改）；`RemoteMacDirectory` 的实现走 `refreshRelayHostsIfStale()`（从 `private` 改成 internal）：已启用（点过「连接我的 Mac」）、在前台、没在问、离上次问过满 `relayPollInterval`（Mac 5 秒、iOS 15 秒）才问一次。设备组 2 秒或 10 秒一轮，所以有事要做、Mac 又一直不在线时，Mac 上 5–10 秒问一次中继，iOS 前台 15–20 秒一次；问完 `macs` 变了，下一轮就排上。

### 核过的事实

- Mac 上的 `isInForeground` 恒为 true：目录按默认值 `startsInForeground: true` 建（`uTermApp`），`enteredBackground` / `returnedToForeground` 只有 iOS 的 `RemoteMacDirectoryLifecycle` 调。所以 Mac 上 App 不在最前面、没有窗口时也会问；iOS 只在前台问（设备组服务在后台本来就停了）。
- 没点过「连接我的 Mac」（`isActivated` 为 false）的设备不问，和别的按需路径一样。那样的设备上设备组只能用 Bonjour 看得到的 Mac——而 Bonjour 浏览也要激活后打开远控窗口才开始。
- 快通道连着那台 Mac（`RemoteGroupFastChannel.sync.linkKind(for:)` 不为 nil）说明它的 App 在线，但没拿它当信号：撤销与开通要问的是本机配对过的每台 Mac，其中不在设备组里的 Mac 没有快通道，只认快通道会漏掉它们；拿它来收窄（只在快通道连着时问）也会让「Mac 离线」和「Mac 在线但不在组里」分不开。两块代码也就不用缠在一起。

### 没改的

- Mac 上 App 启动后不开 Bonjour 浏览，局域网里的 Mac 要等打开远控窗口才算在线；只在局域网里、没配中继的 Mac 上的撤销与开通仍会卡到那时。要不要让设备组有事时也开浏览（iOS 上要权衡耗电），没定。
- 那台 Mac 真的一直不在（关机、卖了）时，有事要做就一直按目录的间隔问中继，iOS 前台 15–20 秒一次，没有退避。之前只在主机页开着时这样问。

### 测试

- `RemoteDeviceGroupRevokeTests` 加 5 条：
  - 离开时 Mac 不在线、又加入 → 「已移除的设备」清空、进度落成 `hosts = []`，Mac 上线后不撤、照常开通，几个 6 小时之后也不撤；
  - 一台 Mac 已撤、一台没撤时又加入 → 没撤的不再撤，撤过的那台在撤销之后又有一次替它开通；之后再被移除 → 两台从头撤，新进度的移除时间晚于这次加入；
  - 撤销请求卡在路上时又加入 → 请求回来后进度仍是 `hosts = []`、`finished` 为空、不撤第二次，那台 Mac 上最后一件事是替它重新开通；
  - 有没撤完的撤销、Mac 不在线 → 每轮请目录补问；开通都做完时、Mac 在线时、撤完之后都不问；
  - 撤销在等 6 小时的重试时 Mac 不在线 → 不问。
- `RemoteDeviceGroupHostsTests` 加 1 条：新组员还没在一台不在线的 Mac 上开通 → 认下它的那一轮就补问；Mac 在线了直接问，开通好之后不再补问；只有自己一台时不问。
- `RemoteGroupHostAccessTests` 加 2 条（真 `RemoteMacDirectory`，假的问中继）：`refreshReachability` 刚问过不问、过了间隔补问一次、一轮里调五次也只问一次、`enteredBackground` 之后不问；没启用时不问。
- `RemoteGroupFakeHosts` 多一个 `reachabilityRefreshes` 计数。
- 五个类共 96 条全过（`RemoteDeviceGroupRevokeTests` 26、`RemoteDeviceGroupHostsTests` 20、`RemoteDeviceGroupTests` 35、`RemoteGroupHostAccessTests` 9、`RemoteDeviceGroupServiceTests` 6）。用变异核过：去掉作废、去掉补问，新加的 6 条组员用例里 5 条红（剩下那条断言的是「不问」）。

### 没验证的地方

- 没上真机：user 那台 MacBook 上卡着的那条进度，按代码会在新版本第一轮 `refresh()` 里作废、「已移除的设备」清空，没亲眼看过。
- 补问之后 mini 能不能经中继真的连上、开通 Duo，走的是原有的连接路径，这次没在真中继上试。

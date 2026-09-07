# 研究记录：接入嘉信（Charles Schwab）做美股量化

**结论先行：要额外申请，但不要钱。** 申请走嘉信开发者门户，两段人工审核，快则几天、慢则两三周；API 本身免费，美股线上交易 0 佣金。真正的代价不在钱，在两处：嘉信没有模拟盘、OAuth 每 7 天要人肉重新登录一次；以及 MayStock 现在整套「7×24、加密对命名、百分比手续费」的假设都要打开重写。thinkorswim 不是第二条路：它是同一个账户的另一个前端，没有自己的 API，thinkScript 不能自动下单。

**日期**：2026-09-07 ｜ **口径**：只看 Trader API – Individual（自己账户自己用），不看机构/合作方产品

---

## 1. 嘉信的程序化交易是什么

嘉信面向个人的接口叫 **Trader API – Individual**，在 developer.schwab.com 上。官方描述（门户产品页原文）：allows you to create your own application for your own self-directed Brokerage account；能力包括 authentication、market data、account information、order/transaction information、order entry、order preview；使用者限定 Individual Developers；联系邮箱 TraderAPI@Schwab.com。

它是 2024 年 5 月 TD Ameritrade API 关停后的继任者。REST（`/trader/v1` 账户与订单、`/marketdata/v1` 行情）+ 一条自有协议的 WebSocket 流（Streamer）。没有官方 SDK、没有官方 CLI，社区库有 Python 的 schwab-py 和 Schwabdev、TypeScript 的 sudowealth/schwab-api、R 的 schwabr。

## 2. 要不要额外申请，要不要钱

| 问题 | 答案 | 依据 |
|---|---|---|
| 要不要单独申请 | **要。** 券商账户 ≠ 开发者账户，后者要另注册、另审核 | 门户「How to get started」四步：Register → Discover → Build → Deploy |
| 审核几段 | **两段。** 先 Request Access「Trader API – Individual」（约 1–2 个工作日），再 Create App（批量审批，常见 10 个工作日以上） | 中文实操教程（LookatWallStreet，面向大陆国际账户用户）；schwab-py 文档把 App 的 `Approved - Pending` 状态解释为「正在人工审批」，要等到 `Ready For Use` |
| 全程多久 | 快的报 1–3 个工作日，慢的报 10–15 个工作日。按两三周排期 | Lumibot 文档 / GitHub 注册指南 / LookatWallStreet |
| API 收费吗 | **不收。** 个人自用免费 | SnapTrade、Lumibot、QuantConnect（Free for Charles Schwab subscription accounts） |
| 行情收费吗 | 不收。实时报价要在券商账户里签交易所协议（非专业用户免费），没签就是延迟报价 | schwabr 文档 |
| 交易佣金 | 美股/ETF 线上 0 佣金；期权每张 US$0.65；卖出时有 SEC fee 和 FINRA TAF 两项监管小额费用 | international.schwab.com |
| 国际账户能不能用 | **能。** 大陆用户用 Schwab One International 账户走通的教程就是这么写的 | LookatWallStreet 教程 |

### 申请步骤（只有你本人能做，我不能替你登录券商身份）

1. 用**和券商账户完全一致**的姓名、邮箱、手机号在 developer.schwab.com 注册开发者账号。信息不一致，后面会被拒。
2. 大陆手机号收境外验证码不稳。教程建议券商账户和开发者账户都绑境外号码；券商账户开了两步验证后可以用 VIP Access 应用出 6 位码，不再依赖短信。
3. 登录后 API Products → Trader API – Individual → Request Access，接受条款，等 1–2 个工作日。
4. 通过后 Dashboard → Apps → Create App。回调 URL 必须是 **https**，允许 `https://127.0.0.1:端口`（例如 `https://127.0.0.1:8182`），长度 ≤256，后续代码里要**逐字符一致**（含大小写和末尾斜杠）。
5. 等 App 状态从 `Approved - Pending` 变成 `Ready For Use`，抄下 App Key / Secret（Secret 只显示一次）。
6. 有问题用英文写邮件给 TraderAPI@Schwab.com。打电话找不到这个团队。

## 3. 能力与硬限制

### 3.1 认证（这是最烦的一条）

- OAuth 2.0 授权码流程。access token 30 分钟，refresh token **7 天**。
- refresh token 过期后不能续，只能重新走一遍浏览器登录。**没有办法把它变成无人值守**：schwab-py 文档明说 login cannot be fully automated。实际做法是每周固定一天（开盘前）手工登录一次。
- 授权码拿到后 30 秒内必须换 token。
- **一个用户同一时刻只能有一个已认证会话**（QuantConnect 文档：Charles Schwab only supports authenticating one account at a time per user；新登录会踢掉旧的）。schwab-py 也要求一个 token 文件只开一个 client。

### 3.2 限频

- 全局 120 次/分钟，超了返回 HTTP 429。
- 下单类请求（place/cancel/replace）每账户可配 0–120 次/分钟；查询订单不限。
- Streamer 建议**所有连接合计不超过 300 个标的**，超过会出现数据不一致。

### 3.3 没有的东西

| 缺失 | 影响 |
|---|---|
| **没有模拟盘 / sandbox**。API 只连真实账户；thinkorswim 的 paperMoney 不对 API 开放 | MayStock「默认 demo」的安全模型要改成本地影子撮合 |
| **没有客户端自定义单号**。下单响应体为空，订单号在 `Location` 响应头里 | MayStock 靠 `clOrdId` 做逐策略归因的机制（`Sources/MayStockKit/Trading/OrderTag.swift:15-45`）在嘉信上没有对应物 |
| 不支持碎股（Stock Slices 只在网页端） | 最小单位 1 股 |
| 不能交易期货、外汇、加密、债券、非美股（期货返回 HTTP 400） | 只做美股/ETF/期权 |
| 期权没有历史 K 线（只有实时流） | 期权策略无法回测 |
| 隔夜（overnight）时段不对 API 开放 | 时段只有 NORMAL / AM / PM / SEAMLESS |

### 3.4 有的东西

- **历史 K 线**：日线/周线可回到 1985 年；1 分钟线只有约一到一个半月；5/10/15/30 分钟线约 9 个月。带 `needExtendedHoursData` 开关。
- **流式行情**：LEVELONE_EQUITIES / OPTIONS / FUTURES / FOREX、CHART_EQUITY（分钟级 OHLCV）、NYSE_BOOK / NASDAQ_BOOK / OPTIONS_BOOK（二档深度）、SCREENER、ACCT_ACTIVITY（账户活动推送）。
- **订单类型**：MARKET / LIMIT / STOP / STOP_LIMIT / TRAILING_STOP(_LIMIT) / MARKET_ON_CLOSE / LIMIT_ON_CLOSE；组合单 SINGLE / OCO / TRIGGER（OTO）；有效期 DAY / GTC / FOK / IOC 等；股票指令 BUY / SELL / SELL_SHORT / BUY_TO_COVER。社区反馈 OCO/OTO 组合与多腿期权「实验性」，上生产前要用小单验证。
- **账户**：余额、持仓、订单、60 天窗口内的交易流水、市场开闭时间（`/marketdata/v1/markets`，可查一年内任意日期）。

## 4. 2026 年的规则变化（对量化直接相关）

- **PDT 规则已经废止。** SEC 于 2026-04-14 批准 FINRA 4210 修订，2026-06-04 生效，取消「5 个交易日内 4 次日内交易」计数和 25,000 美元最低净值门槛，改为按实际日内敞口的 intraday margin 框架，18 个月过渡期到 2027-10-20。嘉信国际站 FAQ 原话：Schwab no longer applies Pattern Day Trading account restrictions。**所以不需要给内核加 PDT 闸。**
- 但保证金账户仍受 intraday margin 与维持保证金约束；**现金账户仍有 T+1 交割和未交割资金违规（settlement violation）**。账户是现金还是保证金，决定了能不能做空、以及要不要加「已交割资金」闸。
- 非美国税务居民要有有效的 W-8BEN，三年一续；没有的话卖出款项被预扣 24%、股息最高 37%。

## 5. thinkorswim 是不是第二条路

**不是。** thinkorswim 是同一个券商账户的另一个前端（桌面 / 网页 / 手机），不是另一套接口。

| 问题 | 结论 | 依据 |
|---|---|---|
| 有没有自己的 API | 没有。TD Ameritrade 时代的 API 已于 2024-05 关停，唯一的接口就是 Trader API；API 下的单会出现在 thinkorswim 里，反之亦然 | TradersPost、useThinkScript |
| thinkScript 能不能自动下单 | 不能。`AddOrder()` 只用于回测显示；社区版主原话：The ToS platform does not support autotrading | useThinkScript |
| 条件单（Order Rules → Method = STUDY）算不算自动化 | 只算半自动：可以用 thinkScript 写触发条件，让一张单在条件为真时提交或撤销。但一次性触发、不保存；study 只能有一个 plot，不能用 HighestAll 这类全图函数；条件代码约 200 字符处会被**静默截断**；复杂脚本超时。没有仓位、组合、归因。是否在平台关闭后仍由服务器评估，官方文档没写，VPS 厂商和社区都按「平台必须一直开着」处理 | thinkorswim 学习中心「thinkScript in Conditional Orders」、useThinkScript |
| paperMoney 模拟盘 | 只能在 thinkorswim 里手动用，API 连不上。能手工验证策略，不能接程序 | Schwab 支持答复（useThinkScript 帖） |
| OnDemand | 历史行情回放，约 14–15 年，手动逐根走。练执行用，不是回测引擎 | 多篇教程 |
| RTD 实时数据到 Excel | 只有 Windows（COM），Mac 上没有 | thinkorswim 学习中心 RTD 页 |
| 第三方「自动化」 | 要么是 UI 自动化（AutoHotkey / UiPath），脆弱且有违规风险；要么是 Windows RTD 转发（Algokick，beta）；要么本质上还是走 Trader API（TradersPost） | useThinkScript「Outside Auto-Trading Solutions」 |
| Mac 上能不能跑 | 能，Intel 版走 Rosetta 2，没有官方 arm64 版 | 社区 |
| 国际账户能不能用 | 能，Schwab One International 免费提供桌面 / 网页 / 手机版 | international.schwab.com |

thinkorswim 对这个项目唯一的用处是**手工验证**。API 没有模拟盘，可以在 paperMoney 里照着策略信号手工下几笔，确认订单类型、时段、成交行为和我们对 API 的理解一致；OnDemand 可以回放特定交易日，检查跳空、半日市这类边界。这两样都替代不了程序化的影子撮合。

## 6. MayStock 现在离「能跑美股」有多远

下面每条都核对过源码位置。

### 6.1 能直接复用

| 层 | 位置 | 说明 |
|---|---|---|
| Rust 内核的纯计算部分 | `kernel/src/{expr,series,sizing,guard,resample,reconcile}` | 无交易所概念 |
| 信号决策 / 回测撮合 | `kernel/src/decide.rs`、`kernel/src/backtest/mod.rs` | 「第 i 根信号 → 第 i+1 根开盘成交」对股票同样正确 |
| 交易端口 | `Sources/MayStockKit/Trading/ExchangeVenue.swift:14-104` | `StrategyRunner` 只认这个协议；`alternativeSeries` / `fundingPayments` 已有默认空实现，正好对应「嘉信没有资金费」 |
| 注入点 | `Sources/MayStock/App/AppState.swift:158-164` | 一行 `var venue: any ExchangeVenue { OKXVenue(bridge: tradeBridge) }` |
| 台账 / 权益曲线骨架 | `Trading/StrategyLedger.swift`、`Trading/AccountEquityCurve.swift` | 结构可留，计价币与时区要换 |
| UI | `Sources/MayStock/{Charts,Panel,StatusBar}` | 与数据源解耦 |

### 6.2 必须新写

| # | 组件 | 落点 |
|---|---|---|
| 1 | `SchwabVenue: ExchangeVenue` | 对标 `Trading/OKXVenue.swift:9-119` |
| 2 | OAuth + REST 客户端、token 存储与刷新 | 现在没有任何凭据存储层，`TradeBridge.hasCredentials()`（`Trading/TradeBridge.swift:366-370`）只是看 `~/.okx/config.toml` 存不存在 |
| 3 | Streamer 客户端 | 与 `OKX/OKXWSClient.swift` 的 `{op,args}` + 文本 `"ping"` 协议完全不同 |
| 4 | **行情端口 `MarketDataFeed`**（现在不存在） | `Engine/MarketHub.swift:20-42` 直接 `new` 出 `OKXWSClient`×2 + `OKXRESTClient`，菜单栏和悬浮面板的行情不走 `ExchangeVenue` |
| 5 | 交易日历（常规/盘前/盘后时段、假日、半日市） | 全仓库零命中 |
| 6 | `StrategyMarket` 加 venue / 资产类别；`InstrumentType` 加股票 | `Strategy/StrategyManifest.swift:5-49, 52-62`；manifest `currentSchema = 1`（`:394`）需 bump 并给迁移路径 |
| 7 | 非比例费用模型 | `Trading/OKXFeeSchedule.swift:188-196` 只有 spot/swap × maker/taker 四个分支，表达不了「0 佣金 + 卖出监管费 + 期权每张费」；且 `Models/StrategyPortfolio.swift:113` 把 `OKXFeeSchedule` 类型写进了持久化配置 |
| 8 | 订单归因的替代方案 | 无 clOrdId，只能在下单返回时把 `orderId → strategyId` 落盘；下单与落盘之间崩溃的订单进已有的「未归因」桶 |
| 9 | 影子撮合（本地纸面交易） | 嘉信无模拟盘，`TradingMode.demo`（`Models/StrategyPortfolio.swift:8-27`）在嘉信上要重新定义 |

### 6.3 会被打破的假设

| 假设 | 位置 | 后果 |
|---|---|---|
| 一年 365 天连续交易 | `kernel/src/strategy.rs:76-78`、`kernel/src/decide.rs:650`、`kernel/src/ffi.rs:562`（默认 365）、`Backtest/BacktestReport.swift:245` | 年化 Sharpe / 波动率系统性高估 √(365/252) ≈ 1.20 倍；波动率目标仓位据此**系统性开小** |
| bar 等间隔、缺口 ≤2% | `kernel/src/quality.rs:65, 87-95` | 把每个收市空档都算成「缺 bar」。日线一年缺 31%，小时线一周缺 80%，**任何时间框架的股票序列都会被判 `usable=false`，策略永久拒绝交易** |
| 最新 bar 落后 >2.5 根 = 断线 | `kernel/src/quality.rs:57, 115-119` | 每天 16:00 ET 后必触发 |
| 心跳 15 分钟不动 = 异常 | `Ops/ReviewPolicy.swift:201-202` | 每晚每周末都报严重告警，复盘器 `--apply` 会自动降敞口 |
| `BASE-QUOTE[-SWAP]` 命名 | `Strategy/StrategyManifest.swift:34-36`、`Trading/StrategyLedger.swift:524-527`、`Models/AppConfig.swift:57-74`、`Trading/StrategyRunner.swift:751, 807` | `AAPL` 被拆成 base=AAPL、quote=USDT；估值时拼出 `AAPL-USDT` 查价必败 |
| 计价币恒为 USDT | `Trading/StrategyRunner.swift:114`（硬编码常量，不读 portfolio 配置） | 改成从 venue 读 |
| 做空 / 杠杆 = 永续专属 | `Strategy/StrategyManifest.swift:24-25, 649-651, 680-687` | 含 `shortEntry` 的股票 manifest 编译期直接抛错 |
| 止损单由交易所 24 小时执行 | `Trading/TradeBridge.swift:622-678`、`docs/KERNEL.md:103-104` | 股票止损单收盘后不工作，隔夜跳空直接穿过。「保护性委托随单挂出」的安全论证在美股只对日内成立 |
| 日内熔断按 UTC 日、「今日」按 Asia/Singapore | `kernel/src/decide.rs:159, 219`、`Trading/AccountEquityCurve.swift:52-62` | 都不是美东交易日 |
| 交易走官方 CLI、App 不碰密钥 | `docs/DESIGN.md:79` | 嘉信没有官方 CLI。这是唯一一条要推翻已写入设计文档的核心决策 |
| lab 缓存键没有 venue 维度 | `Sources/maystock-lab/LabSupport.swift:167-182, 401-403` | `fetchCandles` 默认参数写死 `OKXRESTClient()` |

## 7. 建议方案

### 7.1 凭据边界：新增 `schwabctl`，把 `okx` CLI 的那条边界原样保住

`docs/DESIGN.md:79` 的原则是「App 不接触、不存储任何私钥」。嘉信没有官方 CLI，但这条原则可以靠自己写一个 SwiftPM 可执行目标 `schwabctl` 保住：

- `schwabctl login`：打印授权 URL 并打开浏览器；你登录嘉信后浏览器会跳到 `https://127.0.0.1:8182/?code=…`（页面打不开是正常的），把地址栏整串粘回终端；CLI 在 30 秒内换 token，refresh token 存 Keychain。每周一次。
- `schwabctl token`：吐一个 30 分钟的 access token 给 App 用（Streamer 登录需要）。refresh token 永远不出 CLI。
- `schwabctl quotes / candles / hours / account / orders / fills`：全部 `--json`，和 `TradeBridge.runCLI()`（`Trading/TradeBridge.swift:696-708`）一样的子进程契约。
- 好处：App Key/Secret/refresh token 只在一个进程里；maystock-lab 用同一个 CLI 拉数据；7 天登录变成一条命令。

不选 Python（schwab-py）做 helper：仓库是 Swift + Rust，多一种运行时就多一份安装负担。

### 7.2 内核去「7×24」化，是无论如何都要做的部分

**已完成（2026-09-08）**，实际做法与预案的差别记在括号里：

- `bars_per_year` 从 `MarketCalendar` 算（连续 365.25 天；美股 252 个交易日 × 每日 bar 数）；`quality::inspect` 按日历数缺口与落后，盘前盘后 bar 只报 `offGrid` 不拒绝。（预案说金标会全红——没有：指纹不含年化项，OKX 路径逐 bit 未动，`KernelGoldenTests` 原样通过。）
- 日内熔断的「今天」按 `session_key`：美股是纽约交易日，OKX 仍是 UTC 日。（权益曲线的日历窗口与心跳静默尚未改，它们属于运维层，接交易时一起做。）
- 手续费从一个 bps 数变成费用组件（`kernel/src/fees.rs`），嘉信的 SEC §31 与 TAF 才写得出来；`FeeSchedule` 成为协议，`OKXFeeSchedule` / `SchwabFeeSchedule` 各一份，`StrategyPortfolioPrefs.feeSchedules` 按 venue 存，旧的 `feeSchedule` 键只读不写（AppConfig schema 4）。
- `StrategyMarket.venue`（okx / schwab，缺省 okx），manifest schema 2；`InstrumentType.STOCK`，能否做空、杠杆上限、保证金制度只在内核 `InstrumentPolicy` 里声明一次，Swift 经 FFI 读同一份。
- Swift 侧删掉了所有 `天数 × 86400 / bar` 与 `BASE-QUOTE` 拆字符串的算术：bar 计数问 `KernelCalendar`，计价币与 id 解析问 `Venue`。研究台 `maystock-lab` 的行情拉取仍只有 OKX 一个来源（`requireMarketData` 对 schwab 明确报错），`fees` 同时打印两家，`new --venue schwab` 可生成美股清单。
- 覆盖：内核 211 项、Swift 496 项测试全绿；新增日历、费用、清单 venue、持久化四组测试，全部遍历 `Venue` / `InstrumentType` / `BarInterval` 的声明而不点名。

### 7.3 顺序（依赖最少 → 最多）

0. **今天**：你去开发者门户注册并提交两段申请。等审核的两三周正好做 1。（2026-09-07 已登录门户并打开 Trader API – Individual 的申请弹窗；条款要点见本节末尾。）
1. ~~内核与 manifest 的通用化（7.2）~~ **已完成（2026-09-08）**，全部离线测试。
2. `schwabctl login + candles`，maystock-lab 先跑美股日线研究（日线可回到 1985 年，365 天回测没问题；1H/4H 策略只有约 9 个月的 30 分钟线可重采样，更长要另找数据源）。
3. `SchwabVenue` + 本地影子撮合；再用最小手数上实盘。
4. `MarketDataFeed` 端口 + 菜单栏美股行情。

### 7.4 已拍板（2026-09-07）

| 决策 | 结论 | 对方案的影响 |
|---|---|---|
| 凭据边界 | `schwabctl` 独立子进程 | 7.1 原样执行；`docs/DESIGN.md:79` 的原则改写为「密钥只在 CLI 进程里，App 只拿 30 分钟 access token」 |
| 落地顺序 | 先通用化内核，再研究台，最后接交易 | 按 7.3 走 |
| 账户类型 | 保证金账户 | 做空可开（`SELL_SHORT` / `BUY_TO_COVER`），不加已交割资金闸；要处理借券不可得（hard-to-borrow）时的拒单，以及维持保证金约束。PDT 已废止，日内保证金框架下不再计数 |

### 7.5 开发者协议里和量化直接相关的条款（2023-05 版，2026-09-07 读取）

- 资源目前免费，Schwab 保留收费权（§1）；个人账户只能自用，分发给第三方要注册 Company（§2、§6.2）。
- **§13.1**：所有下单决定（标的、时间、价格）须由 End User 决定，应用不得替 End User 选标的或自主下单，功能须由 End User 的参数输入建立。个人账户下开发者与 End User 是同一人、策略参数由本人配置，这是社区通行的自动交易用法，但 Schwab 保留认定违规并关停 API 的权利。
- 禁止跨用户镜像跟单（§5(x)），禁止用应用以外的脚本抓平台（§5(v)）。
- API Key 只能本人使用（§9.2）；不得保存密码 / PIN，只能保存 Schwab 签发的 token（§9.4.1）——与 `schwabctl` 只存 refresh token 的设计一致。
- 限频可随时调整、订单可能被打标记（§6.7）；API 可无通知修改或停用（§6.6、§12、§21.1）。
- 保留最近 18 个月的使用记录，Schwab 有三年审计权（§10）。
- 按现状提供，赔偿上限 1000 美元（§19）；开发者对因其应用引起的索赔承担赔偿（§18）。
- 条款可单方面修改，继续使用即视为接受；通知邮箱 traderapi@schwab.com（§22.1、§22.3）。

## 8. 来源

- 嘉信开发者门户产品页与首页（developer.schwab.com，2026-09-07 浏览器读取）
- 嘉信国际站 FAQ：international.schwab.com/faqs（PDT 不再适用、结算违规、W-8BEN）
- schwab-py 文档：auth.html（回调 URL、token 期限、`Approved - Pending`）、client.html（历史 K 线深度）、streaming.html（流式频道）、order-builder.html（订单枚举）
- Lumibot Schwab 文档：lumibot.lumiwealth.com/brokers.schwab.html（申请步骤、限频、期货 400）
- QuantConnect Schwab 文档与论坛：单会话限制、300 标的建议
- MyLinedChart「Schwab API for Traders: Costs and Real Limits」：无模拟盘、不支持期货外汇加密债券非美股、期权无历史 K 线
- LookatWallStreet「对接嘉信(Schwab)教程」（2026-08-09）：大陆国际账户申请流程、10–15 个工作日、信息一致、境外手机号
- Federal Register 2026-04-17 / FINRA Regulatory Notice 26-10：FINRA 4210 修订，2026-06-04 生效
- TradersPost / useThinkScript：API 不支持 paperMoney

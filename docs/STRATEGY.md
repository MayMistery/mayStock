# MayStock 策略工作台 — 设计文档

> 把菜单栏行情终端，延伸成一台**低频量化工作台**：导入策略 → 多窗口回测 → 分配仓位 → 启停交易。
> 悬浮面板不再有手动买卖按键，只呈现当前模拟盘/实盘的仓位与收益率。

## 0. 业界方案与本设计的取舍

| 方案 | 策略定义 | 回测报告 | 仓位分配 | 本设计的取舍 |
|------|---------|---------|---------|------------|
| Freqtrade | Python 类（任意代码） | CAGR/Sharpe/Sortino/Calmar/SQN/盈亏比/期望值/回撤，费按进出各收一次、假设零滑点 | `stake_amount` 或余额 ÷ `max_open_trades` | **借**：指标全集、双边计费、次根撮合。**改**：滑点显式建模而非假设为零 |
| Jesse | Python 类 | 净利/浮盈/手续费/最大回撤/年化/期望值/胜率/多空拆分/持仓时长/Omega/连胜连败 | 每 route 固定资金 | **借**：连败与持仓时长等运营指标 |
| Hummingbot | YAML 配 controller + 可选 Python 脚本 | — | 每 controller 独立预算 | **借**：配置与代码分离 |
| Composer (SoFi) | 声明式逻辑树，零代码 | Sharpe/回撤 + 基准对比 | 等权/逆波动率/市值/自定义权重 | **借**：零代码执行的安全边界、基准对比 |
| OKX 原生 bot | grid / dca | — | 每 bot 独立投入额 | **借**：策略即独立资金单元 |

**三处超越点**

1. **表达式 DSL**：Composer 只能点树，Freqtrade 必须写 Python。本设计给出一门可读可写、且**只做数组数学的沙箱表达式语言** —— 既有代码的表达力，又无代码执行的攻击面。
2. **诚实的回测**：次根开盘撮合杜绝未来函数；手续费与滑点双边显式；永续用**真实历史资金费率**而非拍脑袋常数；同根 K 线同时触及止损与止盈时按最坏情况判定。
3. **共享余额下的按策略归因**：交易所只有一个账户余额，业界桌面端普遍算不清「哪笔盈亏属于哪个策略」。本设计用 `clOrdId` 给每笔订单打策略标签，并与 `okx spot fills` 对账 —— 重启、断电、手工干预后仍可还原。

**反过拟合**（研究共识，多数产品不做）：每个自由参数至少需 30 笔独立交易；Sharpe > 3 通常是过拟合信号；样本内外 Sharpe 衰减是最明确的警报。因此 1 日窗口对低频策略常是 0~1 笔交易 —— 照常展示，但强制带上样本量与稳健性徽章。

## 1. 策略清单格式

一个策略 = 一个 JSON 文件。拖进工作台即可回测与运行，全程不执行任何外部代码。

```json
{
  "schema": 2,
  "id": "ema-trend-btc",
  "name": "EMA 双均线趋势",
  "version": "1.0.0",
  "author": "may",
  "notes": "经典趋势跟随；200 日均线之上才做多。",

  "market": { "venue": "okx", "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },

  "params": {
    "fast": { "default": 12, "min": 2,  "max": 100, "label": "快线周期" },
    "slow": { "default": 26, "min": 5,  "max": 400, "label": "慢线周期" }
  },

  "signals": {
    "longEntry":  "ema(close, fast) crosses_above ema(close, slow) and close > sma(close, 200)",
    "longExit":   "ema(close, fast) crosses_below ema(close, slow)",
    "shortEntry": null,
    "shortExit":  null
  },

  "sizing": { "mode": "equityPct", "value": 100 },

  "risk": {
    "stopLossPct": 4,
    "takeProfitPct": null,
    "trailingStopPct": null,
    "atrStop": { "period": 14, "mult": 2.5 },
    "leverage": 1,
    "cooldownBars": 1,
    "minHoldBars": 0,
    "maxDailyLossPct": 5
  },

  "costs": { "feeBps": 10, "slippageBps": 5 }
}
```

- `market.venue`：`okx`（默认）或 `schwab`。`instType`：OKX 为 `SPOT` / `SWAP` / `OPTION`，嘉信为 `STOCK`。做空与杠杆上限由品种决定：现货不能做空、杠杆 1；永续可做空（卖出）、杠杆 ≤ 50；期权的做空信号买入看跌、杠杆 1；美股（保证金账户）可做空、杠杆 ≤ 2。规则只在内核里写一份，清单编译时照它拒绝。`OPTION` 的 `instId` 是信号所读的标的，仓位是它的期权合约，细节见 [STRATEGY-DEV.md §1.5](STRATEGY-DEV.md)。
- `sizing.mode`：`equityPct`（占本策略分配资金的百分比）/ `fixedQuote`（固定计价币金额）/ `riskPerTrade`（按止损距离反推头寸，`value` 为单笔风险百分比）。
- `costs` 省略时按交易所费率表取：OKX 现货 taker 10 bps、永续 taker 5 bps、滑点 5 bps；嘉信美股买入 0、卖出 SEC §31 + FINRA TAF、滑点 2 bps。也可写成费用组件列表 `fees`（按名义额 / 按股数 / 按单，分买卖方向，可封顶），细节见 [STRATEGY-DEV.md](STRATEGY-DEV.md) §3。

### 表达式文法

```
expr        := or
or          := and ( "or" and )*
and         := not ( "and" not )*
not         := "not" not | comparison
comparison  := sum ( ( ">" | ">=" | "<" | "<=" | "==" | "!="
                     | "crosses_above" | "crosses_below" ) sum )?
sum         := product ( ( "+" | "-" ) product )*
product     := unary ( ( "*" | "/" | "%" ) unary )*
unary       := "-" unary | primary
primary     := number | identifier | call | "(" expr ")"
call        := identifier "(" ( expr ( "," expr )* )? ")"
```

- 变量：`open high low close volume hl2 hlc3 ohlc4 bar_index`，以及 `params` 中声明的每个参数名。
- 函数：`sma ema rsi atr stdev highest lowest roc macd macd_signal macd_hist bb_upper bb_lower bb_width ref abs min max sign clamp crossover crossunder`。
- 布尔在内部即 0/1 数值序列，因此 `close > sma(close,20)` 与 `and/or/not` 可自由组合。
- **预热期**用 NaN 表示；任一操作数为 NaN 则结果为 NaN，比较结果为「假」。这保证均线未成型时不会误发信号。

求值是**向量化**的：一次算出整条序列，相同子表达式按结构键记忆化，回测与实盘共用同一套求值器 —— 「回测跑的就是实盘跑的代码」。

### 外部脚本适配器（需显式解锁）

`"engine": { "kind": "script", "command": "/path/to/strategy.py", "args": [] }`
K 线以 JSON 从 stdin 喂入，signals 从 stdout 读回。**这等于在本机执行导入文件携带的任意代码**，因此默认禁用，需在「账户与连接」页显式开启，且每次运行前提示。

## 2. 回测执行模型

| 事项 | 处理 |
|------|------|
| 信号时点 | 第 i 根**已确认** K 线收盘后求值 |
| 成交时点 | 第 i+1 根 K 线**开盘价**，叠加滑点（买入上滑、卖出下滑） |
| 未来函数 | 结构上不可能：求值窗口止于 i，撮合始于 i+1 |
| 手续费 | 按费用组件逐笔计：名义额比例、按股数、按单，各自分买卖方向；美股买入 0、卖出收监管费 |
| 盘中止损/止盈 | 用第 i+1 根起的 high/low 判定；**同根同时触及则判为止损先成交**（最坏假设） |
| 移动止损 | 按每根收盘价更新水位，下一根内触发即平 |
| 资金费（永续） | 取 OKX `funding-rate-history` 真实费率，在结算时刻对持仓名义额计提；多头在费率为正时付出 |
| 强平（永续） | 未实现亏损吃穿 `保证金 × (1 − 维持保证金率)` 即判强平，记为强平事件 |
| 净值 | 每根收盘按市价盯市 |
| 交易日历 | 由 `market.venue` 决定：OKX 7×24；美股按纽交所交易日，缺的周末与节假日不算缺口，年化按 252 个交易日，日内亏损闸按纽约交易日复位 |
| 基准 | 同窗口买入持有收益率，用于计算超额 |

## 3. 多窗口与稳健性徽章

窗口：**1 日 / 7 日 / 30 日 / 90 日 / 365 日**。按最长窗口一次取数，短窗口切片复用，避免重复请求。
长窗口需要 `history-candles` 分页；单次回测的 K 线预算上限 6000 根，超出则截断并在报告中标注。

徽章由四项判据合成：

| 判据 | 阈值 |
|------|------|
| 样本量 | 交易笔数 ≥ 自由参数个数 × 30 |
| Sharpe 警戒 | 年化 Sharpe > 3 视为可疑 |
| 样本内外衰减 | 最长窗口按 70/30 切分，`OOS Sharpe / IS Sharpe` ≥ 0.5 |
| 跨窗口一致性 | 各窗口收益率符号一致 |

→ `样本不足` / `可参考` / `稳健` / `疑似过拟合`。徽章优先级：样本不足 > 疑似过拟合 > 稳健 > 可参考。

## 4. 共享余额下的按策略归因

交易所侧只有一个账户。归因靠三件事：

1. **打标**：每笔订单带 `--clOrdId`，格式 `ms` + 策略 UUID 前 8 位十六进制 + 10 位 base36 序号（共 20 字符，字母开头、纯字母数字，满足 OKX 的 32 字符约束）。
2. **入账**：下单回执与 `okx spot fills` / `okx swap fills` 的成交流水按 clOrdId 归入各策略台账，均价法计算持仓成本与已实现盈亏，未实现盈亏用实时行情盯市。
3. **对账**：台账持仓之和与 `okx account balance-all` / `okx account positions` 的交易所真实持仓比对，差额记为「未归因持仓」（手工下单、外部机器人、历史遗留），显式展示而非悄悄抹平。

## 5. 资金分配与运行控制

- 组合层：总资金（计价币）→ 每策略预算，实时显示已分配 / 未分配；超配在写入前拦截。
- 策略层硬约束：预算上限、杠杆上限、单笔最大名义额、日内最大亏损熔断、冷却与最短持仓根数。
- 状态机：`已停止 → 已布防 → 运行中 → 已停止`；另有 `错误` 与全局 `急停`（一键停全部并撤单）。
- **子进程健壮性**（实盘运行中发现并修复）：每次 `okx` CLI 调用有 15 秒看门狗，
  超时即 `terminate` 再 `SIGKILL`；stdout/stderr **并发读取**，避免子进程写满 stderr
  缓冲区导致的经典管道死锁（okx CLI 会往 stderr 打更新横幅）。
  另有 tick 级看门狗：单次 tick 超过 5 分钟即强制恢复。
  没有这三层，一个挂起的子进程会让运行器**静默停止交易**而界面上毫无迹象 ——
  这是无人值守交易循环最危险的失败模式。
- 安全阶梯沿用现有纪律：默认 `--demo`；实盘需在「账户与连接」页解锁，切换环境前先验证目标账户并确认，每个策略在实盘启动时单独确认。

## 5.0 模拟盘与实盘：两个账户，一次切换

OKX 的模拟交易环境是独立账户、独立 API Key，拿实盘 Key 连模拟盘（或反过来）交易所直接拒绝。
因此：

- 配置里每个环境各有一个 CLI profile（`trading.demoProfile` / `trading.liveProfile`，
  旧配置里的单个 `profile` 迁移时同时填给两边），`TradeBridge` 按每次调用的 `TradingMode` 选 profile。
- App 只读 `~/.okx/config.toml` 的 profile **名字**与 `demo` 标记，密钥本身从不经手；
  profile 标记与目标环境不符时先在界面上警告，不等交易所报错。
- 切换流程：验证目标账户（`okx account balance` + `account config`，只读）→ 说明会停掉几个策略、
  另一边台账有几个持仓 → 确认 → 停止所有策略、重启交易循环、切换。
  重启不是装饰：一次 tick 里每个调用都现读 `portfolio.mode`，不打断它，
  一个按模拟盘账本定量的决定就可能发到实盘上去。`StrategyRunner.place` 在发单前最后检查一次取消。
- 界面上模拟盘一律琥珀色、实盘一律红色，环境栏、面板、菜单三处一致。

## 5.1 菜单栏面板：权益与 1h/1d/7d 收益率

面板顶部固定展示**当前账户权益**与**三个滚动窗口的收益率**。

- **权益以 USDT 计**，而不是交易所返回的 USD 估值（`trading.totalEq`）。
  两者会差 0.1% 左右，而预算、单策略盈亏、仓位大小全部以计价币计 ——
  混用会让 USDT 稍微脱锚时凭空显示出一笔「亏损」。
  只有当某个持仓取不到行情价时，才回退到交易所估值；
  **绝不跳过取不到价的持仓**，那会低估权益、看起来像一笔没发生过的亏损。
- **窗口收益率需要权益时间序列**，台账给不出来：一个整周空仓的策略没有任何成交，
  它的权益却仍在变。因此运行器每 60 秒采一次权益，落在 `equity-{demo,live}.json`，
  与台账一样按模拟/实盘分开。最近 25 小时保留分钟级，更早的按 15 分钟抽稀，
  保留 30 天。
- **记录时长不够的窗口显示「—」**，下方标注已记录多久，而不是拿最早的样本硬算。
  刚装好的应用只有 20 分钟历史，回退计算会让 1h/1d/7d 显示出**同一个数字** ——
  看起来像三个独立测量互相印证，实际上是一个短测量重复了三遍。
  部分覆盖的数值仍保留在 tooltip 里。

面板高度不再写死：`PanelRootView` 上报布局高度，`HoverPanelController` 跟随并重新锚定。
原来写死的 480pt 实际上比内容少约 30pt —— 每加一行都在悄悄裁掉底部。

## 6. 目录

```
Sources/MayStockKit/Strategy/   Indicators · Expression(Lexer/Parser/Eval) · StrategyManifest · StrategyLibrary
Sources/MayStockKit/Backtest/   BacktestEngine · BacktestMetrics · BacktestReport
Sources/MayStockKit/Trading/    TradeBridge · OrderTag · StrategyLedger · StrategyRunner
Sources/MayStock/Terminal/      TerminalWindow（侧栏六页）· StrategiesPage / StrategyDetailView · AccountPage（环境、profile、连接验证、风控与成本）
Sources/MayStock/Panel/         PanelAccountStrip（权益、收益窗口、本标的持仓；只读）
Sources/MayStock/Design/        Theme · Components · ModeSwitch（模拟盘/实盘开关与连接状态芯片）
```

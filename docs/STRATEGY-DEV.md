# 策略开发指南

写一份策略清单，回测它，**验证它**，再决定要不要给它钱。

本文覆盖清单的每个字段、表达式文法、成本模型，以及怎么用 `maystock-lab` 把
「回测很好看」和「未来可能有效」区分开。

---

## 0. 三十秒上手

```bash
./Scripts/new-strategy.sh "我的ETH趋势" trend ETH-USDT 4H
```

它会生成 `Strategies/我的eth趋势.json`，跑一遍回测，**再跑一遍走向前验证**。
顺序是刻意的：只生成文件会诱使你爱上一个没验证过的净值曲线。

单独用各条命令：

```bash
make lab ARGS="list"
make lab ARGS="backtest 01-btc-ema-trend --days 365 --capital 30000"
make lab ARGS="optimize 01-btc-ema-trend --objective calmar --max-dd 10 --min-trades 30"
make lab ARGS="walkforward 01-btc-ema-trend --folds 4"
make lab ARGS="portfolio 01-btc-ema-trend 02-eth-rsi-reversion --weights 0.5,0.5"
make lab ARGS="fees --tier lv1"
```

**回测不需要任何 API Key**，只读公开行情。只有 `fees --sync` 和实盘下单才需要凭证。

---

## 1. 清单字段

```jsonc
{
  "schema": 1,                    // 必填，当前只支持 1
  "id": "my-strategy",            // 省略则从 name 推导
  "name": "我的策略",              // 必填
  "version": "1.0.0",
  "author": "…",
  "notes": "写给三个月后的自己：这套规则为什么成立。",

  "market": {
    "instId": "BTC-USDT",         // 任意 OKX 标的
    "instType": "SPOT",           // SPOT | SWAP（做空与杠杆仅 SWAP）
    "bar": "1H"                   // 1m 5m 15m 1H 4H 1D 1W
  },

  "params": [                     // 也接受字典写法，见下
    { "name": "fast", "default": 12, "min": 4, "max": 60, "label": "快线周期" }
  ],

  "signals": {
    "longEntry":  "…",            // 至少要有 longEntry 或 shortEntry
    "longExit":   "…",
    "shortEntry": null,           // 仅 SWAP
    "shortExit":  null
  },

  "sizing": { "mode": "equityPct", "value": 100 },
  "risk":   { "stopLossPct": 4, "cooldownBars": 1 },
  "costs":  { "feeBps": 10, "slippageBps": 5 },  // 省略则按账户费率档位

  "data":   { "funding": { "source": "fundingRate" } },   // 见 §2.5
  "engine": { "kind": "declarative" }                     // 或 script，见 §2.6
}
```

### params 的三种写法

```jsonc
"params": [ { "name": "fast", "default": 12, "min": 4, "max": 60 } ]   // 保留顺序，推荐
"params": { "fast": { "default": 12, "min": 4, "max": 60 } }           // 按名字排序
"params": { "fast": 12, "slow": 26 }                                   // 只给默认值
```

三种可以混写：`{ "fast": 12, "slow": { "default": 26, "min": 10, "max": 200 } }`。

> **没有 `min`/`max` 的参数无法参与寻优。** `optimize` 只会转动清单里明确
> 说了可以转多远的旋钮。

### 连续敞口：趋势跟随必需

除了 `longEntry`/`shortEntry` 这套**二元**信号，还可以写一条 `exposure` 表达式，
给出 −1..+1 的**连续目标敞口**。写了它就取代进出场信号。

```jsonc
"signals": {
  // AQR 1/3/12 月时序动量等权合成
  "exposure": "(sign(roc(close, 30)) + sign(roc(close, 90)) + sign(roc(close, 365))) / 3"
},
"sizing": { "mode": "volatilityTarget", "value": 40 },   // 目标年化波动 40%
"risk": { "volLookbackBars": 60, "maxExposure": 1, "rebalanceThreshold": 0.1 }
```

**为什么必须有这个**：Moskowitz/Ooi/Pedersen 的趋势跟随一半机制在**仓位大小**上，
二元仓位根本表达不了。实测 TSMOM 是四轮调研里唯一站得住的东西，
见 [RESEARCH-TREND.md](RESEARCH-TREND.md)。

- 现货的负敞口会被钳到 0（不能做空），永续才能真正持有负敞口
- 敞口为 NaN（预热期）一律视为 0，绝不猜
- `rebalanceThreshold` 是必需的：连续信号不设阈值会每根都换手，手续费吃光一切

### sizing.mode

| 模式 | 含义 |
|------|------|
| `equityPct` | 占本策略分配资金的百分比（`value` 为 0~100） |
| `fixedQuote` | 固定名义额，单位为计价币 |
| `riskPerTrade` | 按止损距离反推头寸，使单笔亏损恒为资金的 `value`%。**必须配置止损**，否则清单校验直接拒绝 |
| `volatilityTarget` | `仓位 = 资金 × 目标波动 / 已实现波动`，`value` 为目标年化波动率(%)。**需配合 `exposure` 使用**；`maxExposure` 是安全上限，防止低波动时期把杠杆放飞 |

### risk

| 字段 | 说明 |
|------|------|
| `stopLossPct` / `takeProfitPct` | 相对入场价的百分比 |
| `trailingStopPct` | 移动止损；水位按每根收盘更新，只约束**之后**的 K 线 |
| `atrStop` | `{ "period": 14, "mult": 2.5 }`；与 `stopLossPct` 并存时**取更紧的那个** |
| `leverage` | 仅 SWAP，1~50；现货必须为 1 |
| `cooldownBars` | 平仓后需等待的根数才允许再入场（反手不受限） |
| `minHoldBars` | 持仓至少这么多根才响应离场**信号**；止损不受限 |
| `maxDailyLossPct` | UTC 日内亏损达标即平仓并停到次日 |
| `volLookbackBars` | 波动率估计窗口（默认 60 根），仅 `volatilityTarget` 用 |
| `maxExposure` | 波动率缩放后的敞口上限（默认 1） |
| `rebalanceThreshold` | 目标敞口与现有敞口差异小于此值就不动手（默认 0.1） |

---

## 2. 表达式文法

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
```

**变量**：`open high low close volume hl2 hlc3 ohlc4 bar_index`，以及 `params` 中每个参数名。

**函数**

| 类别 | 函数 |
|------|------|
| 均线 | `sma(x,n)` `ema(x,n)` `wma(x,n)` `rma(x,n)` |
| 摆动 | `rsi(x,n)` `roc(x,n)` |
| 波动 | `stdev(x,n)` `atr(n)` `natr(n)` |
| 极值 | `highest(x,n)` `lowest(x,n)` |
| 复合 | `macd(x,f,s)` `macd_signal(x,f,s,g)` `macd_hist(x,f,s,g)` `bb_upper(x,n,k)` `bb_lower(x,n,k)` `bb_width(x,n,k)` |
| 工具 | `ref(x,n)` `abs(x)` `sign(x)` `min(a,b)` `max(a,b)` `clamp(x,lo,hi)` `crossover(a,b)` `crossunder(a,b)` |

周期参数必须是常量或策略参数（不能随行情变化），且在 1~5000 之间。

### 2.5 另类数据：把价格之外的东西变成变量

`data` 块里声明的每个名字都成为表达式里的变量，按 K 线时间轴对齐：

```jsonc
"data": {
  "funding": { "source": "fundingRate" },                    // 自动解析到 BTC-USDT-SWAP
  "lsr":     { "source": "longShortRatio", "ccy": "BTC" },
  "btc":     { "source": "instrumentClose", "instId": "BTC-USDT" }
},
"signals": {
  "longEntry": "funding < -0.0001 and btc > sma(btc, 50)"
}
```

可用 `source`（`maystock-lab signals` 会实测每个源现在能给多少历史）：

**OKX 交易统计** —— 历史短（1H 只有 30 天、1D 只有 179 天），基本无法验证：

| source | 含义 | 键 |
|---|---|---|
| `fundingRate` | 永续资金费率（小数，0.0001 = 0.01%） | `instId` |
| `openInterestUsd` / `volumeUsd` | 持仓量 / 成交额（USD） | `ccy` |
| `longShortRatio` | 多空账户比，>1 为散户净多 | `ccy` |
| `takerBuyVolume` / `takerSellVolume` / `takerImbalance` | 主动买卖量与失衡度（−1…+1） | `ccy` |
| `marginLoanRatio` | 杠杆借贷比 | `ccy` |
| `instrumentClose` | 另一标的收盘价（跨标的过滤） | `instId` |

**业界公认信号** —— 免费、无需 Key、有多年历史，能真正做验证：

| source | 含义 | 来源 | 历史 |
|---|---|---|---|
| `fearGreed` | 恐惧贪婪指数 0–100 | alternative.me | 8.5 年 |
| `activeAddresses` | 链上活跃地址 | blockchain.info | 17 年 |
| `transactionCount` | 链上交易笔数 | blockchain.info | 17 年 |
| `hashRate` | 全网算力 | blockchain.info | 17 年 |
| `minerRevenue` | 矿工收入 | blockchain.info | 17 年 |
| `onChainVolumeUsd` | 链上转账额 | blockchain.info | 16 年 |
| `dollarIndex` | 美元指数（广义贸易加权） | FRED | 20 年 |
| `sp500` | 标普 500 | FRED | 10 年 |
| `vix` | VIX 恐慌指数 | FRED | 36 年 |
| `treasury10y` | 10 年美债收益率 | FRED | 64 年 |
| `coinbasePremium` | Coinbase 溢价（美国需求代理） | Coinbase + OKX | 1.2 年 |

这些是纯公开 GET，不发送任何账户信息。**实测结论是它们目前都不显著**，
详见 [RESEARCH-SIGNALS.md](RESEARCH-SIGNALS.md) —— 接进来是为了让你能自己验证，
不是为了让你直接用。

> **水平值要先平稳化。** 链上量、美元指数、算力是会连续趋势数年的**水平值**，
> 直接用会被慢趋势主导。写成 `roc(dxy, 30)` 或
> `(dxy - sma(dxy, 90)) / stdev(dxy, 90)` 才是正确设定 ——
> 实测中矿工收入的裸 t 从 −8.53（水平值）掉到 0.23（变化率）。

**对齐规则**：第 i 根 K 线只能看到**时间戳 ≤ 该根开盘时间**的观测，值向前填充，
第一个观测之前为 NaN（未知）。因为信号在收盘时求值，用到的数据必然早已发布 ——
**结构上不可能有未来函数**。

**历史深度是硬约束**：统计类接口不分页，1H 只有 30 天、1D 只有 179 天，
资金费率 93 天。覆盖不足时 `backtest` / `walkforward` 会明确警告，
NaN 区间信号恒为「未知」，策略在那段时间不会开仓。
实测数据与结论见 [RESEARCH-SIGNALS.md](RESEARCH-SIGNALS.md)。

### 2.6 外部脚本策略

声明式表达式覆盖不了的逻辑，可以交给外部程序：

```jsonc
"engine": {
  "kind": "script",
  "command": "Strategies/scripts/momentum.py",
  "args": [],
  "timeoutSeconds": 30
},
"signals": {}          // 脚本策略不需要入场表达式
```

协议 —— stdin 进一个 JSON，stdout 出一个 JSON：

```
in : {"schema":1,"instId":"BTC-USDT","bar":"4H","params":{...},
      "candles":[{"ts":...,"o":..,"h":..,"l":..,"c":..,"v":..}, ...],
      "series":{"funding":[...]}}      // 声明的 data，null 表示未知
out: {"target":["flat","long", ..., null]}   // 每根一个
```

**边界**（这是脚本策略能被安全使用的前提）：

- 默认**禁用**。CLI 需 `--allow-scripts`，App 需在 设置 → 交易 中显式开启。
- 脚本**只决定方向**，不决定仓位、不下单。止损、冷却、最短持仓、
  资金预算、日内熔断、急停仍由清单与工作台控制。
- 超时强杀、输出大小上限、长度与取值严格校验。
- 预热期返回 `null`（未知）而不是 `flat` —— 前者让引擎保持空仓，
  后者是在断言一个你还没有依据的判断。

```bash
maystock-lab backtest 08-script-momentum --days 90 --allow-scripts
```

示例见 [Strategies/scripts/momentum.py](../Strategies/scripts/momentum.py)。

### 三值逻辑：NaN 是「未知」，不是 0

指标预热期返回 **NaN**。这不是实现细节，是安全设计：如果预热期返回 0，
`close > sma(close, 200)` 会在前 200 根全部成立，策略一上来就满仓。

- 任一操作数为 NaN → 算术与比较结果为 NaN
- `truthy(NaN) = false` → **信号永远不会在指标未成型时触发**
- `and` / `or` 走 Kleene 逻辑：`确定为假 and 未知 = 确定为假`
  （趋势过滤没通过时，不管另一条腿在不在预热都不开仓）

### 五个最常见的错误

1. **通道不加 `ref(..., 1)`**
   `close > highest(high, 20)` 里 `highest` 含当根自己，几乎永远为假。
   正确写法：`close > ref(highest(high, 20), 1)`。
2. **把「在上方」当成「穿越」**
   `ema(close,12) > ema(close,26)` 在整个上升段每根都为真。
   要的是 `crosses_above`。
3. **没有趋势过滤的均值回归**
   单边下跌里 RSI 会一路超卖，策略一路接刀。看 `maxConsecutiveLosses`。
4. **忽略换手成本**
   Lv1 现货往返 0.3%。日均来回一次，一个月光成本就 9%。
   先跑 `maystock-lab fees`。
5. **参数越多越好**
   每个自由参数需要 30 笔独立交易才有统计意义。4 个参数 = 120 笔门槛，
   1H 周期一年通常给不到。参数少反而更可能是真的。

---

## 3. 成本模型

回测撮合规则（与实盘运行器共用同一套求值器）：

| 事项 | 处理 |
|------|------|
| 信号时点 | 第 i 根**已确认** K 线收盘后求值 |
| 成交时点 | 第 i+1 根 K 线**开盘价** + 滑点 |
| 手续费 | 进出各按名义额收一次 |
| 同根触及止损与止盈 | **按止损先成交**（最坏假设） |
| 跳空穿过止损 | 按**开盘价**成交，不是止损价 |
| 资金费（永续） | OKX 真实历史费率，在结算时刻计提 |
| 强平（永续） | 亏损吃穿 `保证金 ×(1−维持保证金率)` 即判强平 |

费率默认取账户档位，**默认普通 Lv1**（新账户，最贵的现实情形）：

```bash
maystock-lab fees                 # 看完整档位表
maystock-lab fees --tier vip1     # 换个档位试算
maystock-lab fees --sync          # 从已配置的 okx CLI 拉本账户真实费率
```

清单里写了 `costs` 就以清单为准；没写就跟随档位。

---

## 4. 怎么判断一个策略值不值得给钱

### 回测好看什么都不说明

搜 5000 组参数挑出最好的一组，不是研究，是抽奖后把没中的票扔掉。
`optimize` 因此**总会**报告「无边际时这么多次尝试的期望最好夏普」：

```
运气基准        无边际时 3840 次尝试的期望最好夏普 ≈ 1.86
```

最优夏普没有明显高过这个数，就是搜出了噪声。

### 先看天花板在哪

在研究任何策略之前，先跑一次上帝视角：

```bash
make lab ARGS="oracle --instId BTC-USDT --bar 1D --days 1400 --swings 5,10,20"
```

它做两件事：

1. **完美预知的上限** —— 给它未来数据，完美抓住每个波段能赚多少。
   这是全代码库唯一刻意使用未来函数的地方，用来给一切策略划天花板。
2. **前高前低到底挡不挡得住**（无未来函数）—— 价格回到旧水位时，
   先反向走还是先突破，附 z 检验与扣除成本后的期望。

实测结论：天花板高得离谱（14 个完美波段 = +14,643%），水位也确实有约 60% 的挡住率，
**但边际每次只有 0.1%、机会稀疏、且会随行情衰减**。详见
[RESEARCH-CEILING.md](RESEARCH-CEILING.md)。

先跑这个，能省下大量在错误方向上的力气。

### 先问信号有没有信息，再问策略赚不赚钱

回测把几百根 K 线压成几笔交易，统计力低到无法区分真信号和噪声。
先用信息系数判断信号本身：

```bash
maystock-lab ic sp500 --ccy BTC --bar 1D --days 2000 \
  --horizons 1,7,30 --transform roc:30 --trials 66
```

四个必须看懂的数：

| 指标 | 含义 |
|---|---|
| **修正 t** | 裸 t ÷ √h。h 根前瞻的相邻观测共享 h−1 根，有效样本约 n/h。**只看这个**，裸 t 恒被高估 |
| 有效样本 | n/h。64 个观测得出的结论，不管 t 多好看都是脆的 |
| 多重检验门槛 | 试了 N 组就要用 `--trials N`，门槛会从 2 抬到更高（66 组 → 3.2） |
| `--transform` | 非平稳水平值必须先转成 `roc:N` 或 `z:N`，否则测的是共同趋势不是预测力 |

分位收益还要**单调**：只有首尾两端有差异、中间乱跳，边际多半来自个别极端值。

### 走向前验证是唯一有意义的检验

```bash
maystock-lab walkforward my-strategy --folds 4 --in-sample 0.7
```

把历史切成 4 折，每折用前 70% 寻优、后 30% **盲测**，最后把所有样本外段拼接起来。
拼接曲线是**你真正可能拿到的结果**。

判据：

| 指标 | 门槛 |
|------|------|
| 效率比（样本外收益 / 样本内收益） | ≥ 0.5，低于即过拟合 |
| 盈利折数 | ≥ 60% |
| 样本外总收益 | > 0，否则不必谈 |

行业经验值：回测收益到了样本外平均衰减约 26%。**衰减是常态，不衰减才可疑。**

### 稳健性徽章

工作台与 `backtest` 都会给出四档：

| 徽章 | 含义 |
|------|------|
| 样本不足 | 交易笔数 < 参数数 × 30 |
| 疑似过拟合 | 样本内夏普 > 3，或样本外效率 < 0.5 |
| 可参考 | 样本量够、无明显过拟合，但跨窗口方向不一致 |
| 稳健 | 样本足、衰减可控、各窗口同向 |

---

## 4.5 横截面因子（多标的）

前面所有内容都是**给单个币择时**。学术界对加密市场唯一有稳健证据的方向是
**横截面**：在几十个币之间互相排序，做多一档做空另一档。

```bash
make lab ARGS="factors --size 40 --days 365 --rebalance 7 --lookback 28 --skip 7"
```

三个因子来自 Liu, Tsyvinski & Wu (*JF* 2022)：市场（等权基准）、
规模（−log 市值，小市值得分高）、动量（过去 N 根收益，跳过最近一期避开反转）。

**必读的三件事**：

1. **稳定币必须剔除。** 收益 ≈0、波动 ≈0 的资产在任何风险调整排序里自动获胜。
   工具按名单 + 年化波动 <5% 双重剔除，并列出剔了谁。
   实测：不剔除时规模 t = 2.29，剔除后 1.70。
2. **幸存者偏差是这类研究的头号杀手。** 宇宙取自今天仍在上市的币，
   退市和归零的从未进入样本。工具每次强制打印这条。
3. **多空那一列通常拿不到。** 现货做空要杠杆账户，且未计融券成本。
   **「仅做多」才是现货能直接实现的口径。**

实测结论是这两个因子在当前条件下都不成立（规模对宇宙大小极度敏感、
动量符号与文献相反），详见 [RESEARCH-FACTORS.md](RESEARCH-FACTORS.md)。

## 5. 组合

```bash
maystock-lab portfolio 01-btc-ema-trend 02-eth-rsi-reversion \
  --weights 0.5,0.5 --capital 30000 --days 365
```

输出里最该看的是**腿间相关性**和**分散化**两行：

```
分散化    各腿加权回撤 12.40% → 组合 11.80%（改善 0.60%）
相关性    01-btc-ema-trend ↔ 02-eth-rsi-reversion = 0.83   （过高，几乎没有分散效果）
```

BTC 与 ETH 的日收益长期高度相关，**「BTC + ETH」本身不构成分散**。
真正的分散来自**低相关的信号逻辑**（趋势 + 回归、不同周期），而不是两个同步的标的。

---

## 6. 从研究台到实盘

1. `walkforward` 通过 → 把 `Strategies/<id>.json` 拖进 MayStock 策略工作台。
2. 先在**模拟盘**分配小仓位跑，对比实盘成交与回测假设的偏差。
3. 设置 → 交易 里解锁实盘，再在工作台逐个策略切换。
4. 每笔订单都会带 `clOrdId` 策略标签，工作台按标签与 `okx spot fills` 对账，
   对不上的部分显式标为「未归因」。

安全阶梯：默认模拟盘 → 实盘需全局解锁 → 每个策略单独确认 → 随时可急停（停全部并平仓）。

# 交易内核（Rust）

> 量化策略实际运行的内核是 Rust。Swift 保留 UI、交易所连接与持久化。

## 1. 边界怎么划的

| 归属 | 内容 | 为什么 |
|---|---|---|
| **Rust**（`kernel/`） | 指标库、表达式 DSL（词法/语法/求值）、回测引擎（二值 + 连续敞口）、绩效指标、仓位计算、**实盘信号决策** | 确定性计算。正确性与可复现性是第一位的，且这里是「回测与实盘必须一致」的地方 |
| **Swift**（`Sources/`） | SwiftUI 界面、菜单栏、OKX REST/WebSocket、okx CLI 桥、配置与台账持久化、异步编排 | 平台 I/O。URLSession、async/await 和 AppKit 在这里是正确的工具，搬进 Rust 只会重复造轮子 |

**没有把网络和下单搬进 Rust**，因为那部分的难点是并发与平台集成，不是计算，Swift 做得更好。

## 2. 这次重构真正买到了什么

不是性能。是**消除了一个结构性风险**。

重构前：
- `BacktestEngine.desiredDirection` —— 回测的信号判定
- `StrategyRunner.decide` —— 实盘的信号判定

两个独立的 Swift 函数，靠一句注释「Mirrors BacktestEngine.desiredDirection」约束它们一致。
任何一边改动而另一边忘了改，结果就是**实盘交易的规则与你回测过的规则不同**，
而且不会有任何报错 —— 这是量化系统里最贵的一类 bug。

重构后：只有一个 `decide::desired_direction`，回测在第 i 根调用它，实盘在最新已确认 K 线上调用它。
**它们不可能不一致，因为只有一个。**

[KernelGoldenTests.swift](../Tests/MayStockKitTests/KernelGoldenTests.swift)
里的 `theLiveDecisionMatchesTheBacktestBarForBar` 把这条性质钉成了测试：
逐根前推调用实盘决策，必须复现向量化回测得到的同一串信号。

## 3. FFI 形状

```c
MSStrategy *ms_strategy_compile(const char *manifest_json, const char *known_series_json, char **err);
char       *ms_strategy_decide (const MSStrategy *, const MSCandle *, size_t, int32_t current, int64_t held,
                                const char *ext, double equity, double held_base,
                                double day_start_equity, double leverage_cap, char **err);
char       *ms_backtest_run    (const MSStrategy *, const MSCandle *, size_t, const char *config_json, char **err);
void        ms_strategy_free(MSStrategy *);
void        ms_string_free(char *);
```

- **K 线走裸 `#[repr(C)]` 数组**：6000 根约 330 KB，每个 tick 序列化成 JSON 的开销比它喂的计算还大。
  `kernel/src/candle.rs` 里有一条单元测试断言 `size_of::<Candle>() == 56`，
  布局改了就编译期失败，而不是把价格当成时间戳解释。
- **配置与结果走 JSON**：它们小、形状会随功能变，手写一份 `BacktestResult` 的 C 结构体
  只会变成永久的布局 bug 来源。
- **编译后的策略是不透明句柄**：解析清单不免费，而实盘运行器每 20 秒就要用一次。
- **每个入口都包了 `catch_unwind`**：panic 跨 FFI 边界是未定义行为，
  而这个库被加载进持有交易所会话的进程里 —— 必须以错误字符串失败，不能以崩溃失败。

## 4. 编译时就拒绝，而不是第一根 K 线上才炸

`CompiledStrategy::compile` 会拿 4 根假 K 线把每条表达式**真的跑一遍**。
这样未知函数、参数个数不对、周期非法都在导入时被拒绝。

刻意没有再写一张校验表：第二张表就是第二个需要与求值器保持同步的东西，
而它们不同步的那个场景，恰恰就是「策略导入时干干净净，然后在持仓状态下失败」。

## 3.1 `decide` 返回的是完整下单计划，不只是方向

```json
{ "target": -1, "targetExposure": -0.333, "targetBaseQuantity": -0.2051,
  "baseDelta": -0.0886, "shouldTrade": true, "haltDailyLoss": false,
  "reason": "敞口 -0.193 → -0.333" }
```

**仓位计算、再平衡阈值、日内亏损熔断三样都在内核里**，Swift 只负责把
`baseDelta` 发出去。运行器里不再出现任何 `sizing.mode` / `maxDailyLossPct` /
`rebalanceThreshold`。

之前这三样在 Swift 各有一份，而且**已经漂移了**：Swift 的 `riskPerTrade` 只认
百分比止损，遇到只声明 ATR 止损的清单会回退到满仓 —— 同一份清单，回测每笔冒
1% 风险，实盘押上全部预算。

`kernel/src/sizing.rs` 是这次抽出来的共用模块，回测的 `open_position` 和实盘的
`decide_live` 调的是同一个 `target_notional` 与 `stop_distance`。
[LiveSizingParityTests](../Tests/MayStockKitTests/KernelGoldenTests.swift)
把这条性质钉死：同一根 K 线、同样的资金，实盘计划开出的名义额必须等于回测开出的。

一个刻意的设计：**取不到仓位大小时，`target` 仍然报出信号方向**，只是
`shouldTrade` 为 false。把它报成「空仓」会让调用方以为策略没有观点，
而事实是它有观点但执行不了 —— 状态栏要显示的正是后者。

## 4.1 迁移已完成，Swift 侧没有第二份实现

已删除：`Indicators.swift`、`StrategyExpression.swift`、`StrategyEvaluator.swift`、
`ContinuousExposure.swift`，以及 `BacktestEngine` 的整个循环和 `BacktestMetrics` 的统计计算。

保留的是**类型**不是**算法**：`BacktestResult` / `BacktestTrade` / `BacktestMetrics`
仍是 Swift 值类型（界面代码大量使用），但它们的数值全部来自内核。
`BacktestEngine` 缩成一个 60 行的门面，`CompiledStrategy` 只持有清单 + 内核句柄。

两个刻意的例外，都不是引擎逻辑：

- `Statistics`（均值/标准差/下行标准差）—— 相关性、IC、因子回归用的通用统计量，
  不是回测报告的绩效指标。绩效指标只有内核一份。
- `ForesightAnalysis`（波段识别、完美预知上限、水位可靠性）—— 全代码库唯一刻意
  使用未来函数的研究工具，不是交易引擎，不参与任何下单决策。
- `StrategyManifest.marketSeriesNames` —— 只用来阻止 `data` 块跟内置行情变量重名，
  是清单层的策略而非求值逻辑。

`maystock-lab` 的 `--transform`（diff / roc:N / z:N）改成用内核 DSL 表达式求值，
所以 `roc` 和 `stdev` 在研究工具里和在策略清单里是同一个东西。

## 5. 验证：从差分改成黄金数据

删掉任何 Swift 计算代码之前，先证明两边算出同一个结果。18 个差分测试当时全绿：

- 28 条指标/表达式逐根比对（含 Kleene 三值逻辑的判定用例）
- 8 组完整回测**逐笔**比对：均线交叉、止损+止盈同根、移动止损、ATR 风险定仓、
  日内熔断、冷却与最短持仓、永续做空+杠杆、连续敞口波动率目标
- 每笔比方向、成交价、数量、净盈亏、持仓根数、离场原因
- 再比总权益、净值曲线长度、夏普、索提诺、回撤、胜率、期望、费用、暴露度
- 容差 1e-9（指标）/ 1e-6（金额），只留浮点累积误差的余地

Swift 引擎删除后，差分测试失去了对照物，于是改成
[KernelGoldenTests.swift](../Tests/MayStockKitTests/KernelGoldenTests.swift)：
把当时两边一致的那组数值冻结成黄金值（8 个场景 × 成交数/终值/收益/回撤/胜率/手续费）。
之后任何改动内核的编辑，只要挪动了一笔成交、一个成交价或一项指标，就必须**显式**改这些数字 ——
这正是无声数值漂移需要的那个复核时刻。重新生成用
`MAYSTOCK_PRINT_GOLDENS=1 swift test --filter KernelGolden`。

**移植过程中真的被抓到四个差异**（都已修）：

1. `wma` 的 `x[i - period + 1 + k]` —— Swift 用有符号 `Int` 算中间值没问题，
   Rust 的 `usize` 在 `i - period` 这一步就下溢 panic。
2. 内核最初只在编译期检查标识符，未知函数/非法周期要到求值时才报错，
   比 Swift 宽松。用第 4 节的试跑修掉了。
3. 那个试跑一开始用空的外部序列表，于是合法引用 `funding_rate` 的清单
   会被自己的探针判成「未知变量」。改成把已声明的序列填进探针。
4. 现货清单声明做空时，内核的通用拒绝信息盖掉了 Swift 更精确的
   `shortingRequiresSwap`。把市场策略检查移到内核编译之前。

## 6. 构建

```bash
make kernel        # 只编 Rust
make build         # 内核 + Swift（build/test 都会先编内核）
cd kernel && cargo test
```

`Scripts/build-kernel.sh` 在静态库变化时会 `touch Sources/CMayStockKernel/shim.c`。
**这一步是必须的**：SwiftPM 不跟踪通过 `unsafeFlags` 找到的库，
否则重编内核后 Swift 侧仍链接着旧的那份 —— 测试会对着一份已经不存在的代码通过。
这个坑在本次重构里真的踩到过一次。

# 示例策略清单

这些文件是**可直接运行的教材**：每个都能回测、寻优、走向前验证，也能直接拖进
MayStock 策略工作台。JSON 不支持注释，所以讲解写在这里。

先读 [../../docs/STRATEGY-DEV.md](../../docs/STRATEGY-DEV.md) 了解字段与表达式文法。

```bash
maystock-lab list                                  # 看有哪些
maystock-lab backtest 01-btc-ema-trend --days 365  # 回测
maystock-lab walkforward 01-btc-ema-trend          # 验证（重要）
```

## 01-btc-ema-trend.json — 趋势跟随

最经典的形态：快慢 EMA 金叉入场、死叉离场，外加 200 根均线做方向过滤。

```
longEntry: ema(close, fast) crosses_above ema(close, slow) and close > sma(close, trend)
```

**要点**

- `crosses_above` 只在**真正穿越**那一根为真（前一根在下、当根在上），不是「一直在上方」。
  写成 `ema(close,12) > ema(close,26)` 会在整个上升段每根都发信号，被冷却与最短持仓挡掉一部分，
  但语义完全不同。
- 趋势过滤是这类策略的命根子：去掉 `close > sma(close, trend)`，震荡市里会被反复打脸。
- 三个自由参数 → 稳健性阈值是 90 笔交易。1H 周期一年大约能给到 60 笔，**天然样本不足**，
  所以徽章会显示「样本不足」，这是诚实的，不是 bug。

## 02-eth-rsi-reversion.json — 均值回归

RSI 从超卖区回升时买入，回到中性区离场，同样带趋势过滤。

**要点**

- 入场用 `rsi(...) crosses_above oversold` 而不是 `rsi(...) < oversold`：
  前者等**回升确认**，后者是在下跌途中接刀。
- 均值回归的持仓时间短、换手高，**手续费敏感度远高于趋势策略**。
  Lv1 现货往返 0.3%，如果平均每笔只赚 0.5%，成本就吃掉六成。
  跑 `maystock-lab fees` 看清这笔账再调参数。
- 配了 `takeProfitPct`，回归类策略需要主动止盈，否则利润会还回去。

## 03-btc-donchian-breakout.json — 通道突破

海龟式：突破前 N 根高点做多，跌破 M 根低点离场，ATR 动态止损。

**要点**

- 通道一律写 `ref(highest(high, entryLen), 1)`。**不加 `ref(..., 1)` 是初学者最常见的错误**：
  `highest(high, 20)` 包含当根自己，`close > highest(high,20)` 几乎永远为假。
- `sizing.mode = riskPerTrade` 按止损距离反推头寸：止损越远、仓位越小，
  每笔亏损恒定为资金的 1%。这要求必须配置止损，否则清单校验会直接拒绝。
- 突破策略胜率天生偏低（三成上下）但赔率高，看 `profitFactor` 和 `payoffRatio`，
  别看胜率。

## 04-eth-bollinger-range.json — 区间低吸

跌破布林下轨后回升买入，摸到中轨止盈。

**要点**

- 只在震荡市有效。单边下跌时会连续触发止损 —— 看 `maxConsecutiveLosses`。
- `bb_lower(close, period, mult)` 的 `mult` 是小数参数，声明了 `step: 0.25`，
  寻优时按 0.25 步长扫描而不是整数。
- 想要真正的多层网格挂单，用 OKX 原生的 `okx bot grid`；本引擎是**单仓位模型**，
  同一时刻只持有一个方向的一个仓位。

## 05-btc-eth-pair.json 与配对用法

两个单腿策略组成组合：

```bash
maystock-lab portfolio 01-btc-ema-trend 02-eth-rsi-reversion \
  --weights 0.5,0.5 --capital 30000 --days 365
```

组合命令会给出**腿间相关性**。BTC 与 ETH 的日收益相关性长期在 0.8 以上，
所以「BTC + ETH」几乎**不构成分散**——组合回撤不会比单腿低多少。
真正的分散要来自**低相关的信号逻辑**（例如趋势 + 回归），而不是两个高度同步的标的。
命令输出里的「分散化」一行就是在量化这件事。

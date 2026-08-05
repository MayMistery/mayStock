<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="MayStock">
</p>

<h1 align="center">MayStock 2.0</h1>

<p align="center">优雅的 macOS 菜单栏行情终端：实时价格、趋势、图表、告警与 OKX 交易联动。</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="docs/DESIGN.md">设计文档</a> ·
  <a href="https://github.com/MayMistery/mayStock/releases">Release</a> ·
  MIT
</p>

---

## 功能

- **菜单栏即趋势**：每个标的显示为 `₿ 118,234 ▲1.24% ▁▂▄▆▇` —— 等宽数字、
  涨跌着色、实时 sparkline；样式与趋势窗口逐标的可配。
- **悬浮图表面板**：鼠标悬停浮现（**不抢焦点**），K 线 + MA20 + 成交量、
  tick 级折线、50 档深度图，十字光标读数、24h 统计、买一/卖一。点击菜单栏图标可钉住。
- **高频数据**：OKX v5 双 WebSocket（`tickers`/`books5` 走 `/public`，
  `candle*` 走 `/business`），~100ms 推送；启动与切周期时 REST 回填 300 根 K 线；
  客户端主动 ping 保活；断线指数退避重连并自动重订阅。
- **触发通知**：价格上/下穿（带迟滞防抖）、24h 涨跌幅、N 分钟波动；系统通知 +
  可选提示音 + 可选 shell hook（注入环境变量，可直接串官方 `okx` CLI 实现「触价下单」）。
- **策略工作台**：导入声明式策略清单（JSON），一次跑出 **1/7/30/90/365 日**回测 ——
  收益、回撤、夏普、盈亏比、对标买入持有，并给出**稳健性徽章**（样本量、样本外衰减、
  跨窗口一致性），用不了的数字会被明确标成「样本不足」而不是拿来骗人。
  然后分配仓位、一键开始/结束交易。策略清单只做数组运算，**不执行任何外部代码**。
- **仓位归因**：交易所只有一个账户余额，MayStock 给每笔订单打 `clOrdId` 策略标签，
  与 `okx spot fills` 对账，因此每个策略的持仓、已实现/浮动盈亏、收益率都算得清；
  对不上的部分显式标为「未归因」，不会悄悄抹平。悬浮面板只展示仓位与收益率，不提供手动下单。
- **交易联动**：走 OKX 官方 CLI（Agent Trade Kit）。默认模拟盘（`--demo`）；
  实盘需显式解锁 + 逐策略确认。MayStock 不接触、不存储任何 API Key。
  **回测只用公开行情，不需要任何凭证。**
- **量化研究台**（`maystock-lab`）：网格寻优、**走向前验证**、组合回测与相关性、
  OKX 费率档位试算（默认普通 Lv1，可 `--sync` 拉取本账户真实费率）。
  寻优会同时报告「无边际时纯运气能达到的期望最好夏普」，用来识别过拟合。
  内置 20 个可声明的信号源（恐惧贪婪、链上、美元指数/VIX/美债、Coinbase 溢价等，
  免费无需 Key，最长 65 年历史），配 `ic` 信息系数分析（含重叠窗口与多重检验修正）。
  见 [docs/STRATEGY-DEV.md](docs/STRATEGY-DEV.md)。
- **自选列表**：任意 OKX 现货/永续标的，添加时经交易所校验。默认 BTC-USDT。

```bash
./Scripts/new-strategy.sh "我的ETH趋势" trend ETH-USDT 4H   # 脚手架 + 回测 + 走向前验证
make lab ARGS="walkforward 01-btc-ema-trend --folds 4"
make lab ARGS="portfolio 01-btc-ema-trend eth-4h-breakout --weights 0.5,0.5 --capital 30000"
```

## 从 Release 安装

1. 从 [GitHub Releases](https://github.com/MayMistery/mayStock/releases)
   下载 `MayStock-v2.0.0-macos.zip`。
2. 解压后把 `MayStock.app` 拖到 `/Applications`。
3. 启动 MayStock。它是菜单栏应用，不会显示 Dock 图标。

## 从源码构建

```bash
git clone https://github.com/MayMistery/mayStock.git
cd mayStock
./Scripts/make.sh run   # 构建 -> /Applications/MayStock.app -> 启动
```

Makefile 会委托到同一个脚本，所以 `make run` 也可用。要求 macOS 15+、
Swift 6 工具链；当前 release 使用 Apple Swift 6.3.2 Command Line Tools 验证。

可选交易支持：

```bash
npm install -g @okx_ai/okx-trade-cli
okx config   # API Key 存在官方 CLI 里，不经过 MayStock
```

## 端到端验证

```bash
./Scripts/make.sh verify   # Release 构建 + 32 个单测 + 连真实 OKX 的 E2E
```

`maystock-e2e doctor` 走的就是 App 线上同一套代码：REST 行情/元数据/回填、
双 WebSocket、实时 tick/K线/盘口、REST/WS 价格一致性。`okx` CLI 检测单独报告；
未安装可选 CLI 时，交易功能会在 App 内保持隐藏。

## 交互

| 操作 | 效果 |
|------|------|
| 悬停菜单栏项 | 浮现图表面板（不抢焦点） |
| 左键点击 | 钉住 / 取消钉住面板 |
| 右键点击 | 设置 / 关于 / 退出 |
| 面板内 + | 一键添加当前价告警 |

## 图标

按 [docs/ICON_PROMPT.md](docs/ICON_PROMPT.md) 的 prompt 生成 1024×1024 PNG，
切图放入 `AppIcon.appiconset`，`make run` 自动打包 `.icns`。

## 许可

[MIT](LICENSE)

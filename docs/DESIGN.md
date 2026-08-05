# MayStock 2.0 — 设计文档

> macOS 菜单栏行情终端：垂直做深「行情监控 + 趋势可视化 + 告警 + 交易联动」。
> 目标：这个垂类里世界第一优雅。

## 0. 对 1.x 的深度 Review（为什么要完全重做）

| # | 问题 | 严重度 | 2.0 的解法 |
|---|------|--------|-----------|
| 1 | **K 线频道订阅在错误的 endpoint**。OKX 于 2023-06-20 将 `candle*` 频道迁移至 `wss://ws.okx.com:8443/ws/v5/business`，1.x 仍订阅 `/public`，服务端直接报错 → 图表永远 "No Data"（`.trae/specs/fix-no-data-charts` 治标未治本） | 致命 | 双 socket 架构：public（tickers/books5）+ business（candle*），由 `MarketHub` 统一复用 |
| 2 | **没有历史回填**。K 线只靠 WS 增量推送，启动后要等很久才有图 | 致命 | 启动即 REST `GET /api/v5/market/candles` 回填 ≤300 根，WS 增量按 ts 合并 |
| 3 | **心跳方向写反**。OKX 要求*客户端*在空闲 <30s 时主动发 `"ping"`、等 `"pong"`；1.x 却在等服务端 ping 再回 pong → 空闲 30s 必掉线 | 致命 | 空闲 18s 主动 ping，10s 未见任何消息判死重连（指数退避 + 抖动 + 自动重订阅） |
| 4 | **假连接状态**：`resume()` 后立即置 `connected`；`isConnected` 永远 true；重试计数永不复位 | 高 | 真实状态机 idle→connecting→connected→degraded，UI 有连接指示灯 |
| 5 | **24h 涨跌幅从未赋值**（`priceChange24h` 恒 0），UI 显示空字符串 | 高 | 从 ticker 的 `open24h/last` 计算，涨跌用色 + 箭头 |
| 6 | **菜单栏是纯文本** `BTC 62213 | CPU 12%`，无趋势、无颜色、无 sparkline —— 与「显示趋势」的核心需求相悖 | 高 | 每个标的独立 NSStatusItem：`图标 + 价格(等宽数字) + ±% + sparkline 迷你图`，逐项可配 |
| 7 | **hover 用 transient NSPopover + 全局事件监视器 hack**，抢焦点、关不掉、体验糟 | 高 | 非激活 NSPanel（不抢焦点），进出带宽限时 + 渐隐动画，点击可钉住 |
| 8 | **CPU/MEM/NET 与行情揉在一起**，定位涣散 | 中 | 全部移除，专注行情垂类 |
| 9 | **模型带 `let id = UUID()` 且参与 Equatable** → 每帧全量 diff，SwiftUI 无效重绘 | 中 | Candle 以 `ts` 为身份，值语义严格 |
| 10 | **“测试”是 assert 的静态函数枚举**，release 下 assert 是空操作；UI 测试是空壳；无 E2E | 高 | swift-testing 单测（fixture 驱动）+ `maystock-e2e` 真实连 OKX 的端到端驱动 + `make verify` |
| 11 | 无通知、无告警、无交易能力 | — | AlertEngine + UNUserNotification + OKX 官方 CLI 交易桥 |
| 12 | JSONSerialization 手工挖字段、魔法数散落、Timer 轮询 0.5s 重画菜单栏 | 中 | 全 Codable 强类型解码；事件驱动 + 10Hz 合并节流 |

## 1. 产品形态

```
菜单栏（每个标的一个 item，可配置样式）
┌──────────────────────────────┐
│ ₿ 118,234 ↑1.2% ▁▂▃▅▆▇       │   ← 等宽数字 + 涨跌色 + sparkline
└──────────────────────────────┘
          │ hover（150ms 后浮现，不抢焦点；点击=钉住）
          ▼
┌───────────────────────────────────────────┐
│ BTC-USDT        118,234.5   ↑ +1.24% 24h  │  ● live
│ ┌───────────────────────────────────────┐ │
│ │   K线 / 折线 / 深度 / 成交量  ·  1m…1D  │ │  ← Canvas 高帧渲染
│ │   MA20 · 最新价虚线 · 十字光标读数      │ │
│ └───────────────────────────────────────┘ │
│ 24h高 119,102  低 116,880  量 12.4K BTC   │
│ 买一 118,234.4 │ 卖一 118,234.5  价差 0.1  │
│ ⚑ 告警: >120,000 ·  +添加当前价告警        │
│ DEMO  多 0.0142  +12.40 (+1.24%)  工作台 → │
└───────────────────────────────────────────┘
```

> 2.1 起面板不再有手动买卖按键：下单一律经由策略工作台按信号自动执行，
> 面板只呈现当前模拟盘/实盘的仓位与收益率。详见 [STRATEGY.md](STRATEGY.md)。

- 多标的：任意 OKX 现货/永续 instId（BTC-USDT 为默认练手标的）。
- 更新频率：tickers/books5 推送 ~100ms 级；菜单栏渲染合并节流至 10Hz；sparkline 1s 采样。
- 右键菜单：设置、暂停刷新、关于、退出。

## 2. 架构

```
┌────────────────────────── MayStock.app (macOS 15+, AppKit+SwiftUI) ─────────────────────────┐
│ StatusItemController ── SparklineRenderer(CG)                                               │
│ HoverPanelController(NSPanel .nonactivating) ── PanelRootView(SwiftUI)                      │
│     Charts: CandleChart · DepthChart · LineChart · VolumeStrip   (全部 Canvas 自绘)          │
│ SettingsScene: Watchlist · Alerts · Trading · General                                       │
│ NotificationService(UNUserNotificationCenter, bundle-guarded)                               │
└──────────────△──────────────────────────────────────────────────────────────────────────────┘
               │ @Observable (InstrumentSession / ConfigStore / AlertCenter)
┌──────────────┴────────────── MayStockKit（纯 Foundation，Linux 可编译）────────────────────────┐
│ MarketHub ── OKXWSClient ×2 (public/business, actor)                                        │
│           ── OKXRESTClient (candles 回填 / books / instruments / ticker)                     │
│           ── OKXWireDecoder (强类型 Codable)                                                 │
│ InstrumentSession: ticker · candles[bar] · book · SparklineBuffer(ring)                     │
│ AlertEngine: 规则求值(去抖/冷却/自动重挂) → AlertEvent                                        │
│ TradeBridge: 官方 okx CLI (Agent Trade Kit) 子进程封装, --json / --demo                      │
│ ConfigStore: 版本化 JSON (v2, 自动迁移 v1, 丢弃 cpu/mem/net 项)                              │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

**关键决策**

1. **Kit 与 App 分层**：MayStockKit 不依赖 AppKit，可在 Linux/CI 编译测试 —— E2E 驱动 `maystock-e2e` 直接复用同一套引擎，「测试的就是线上跑的代码」。
2. **双 WebSocket 复用**：public 与 business 各一条连接，所有标的共享；订阅表由 MarketHub 维护，重连后自动重放。
3. **数据正确性**：K 线以 `ts` 为主键 replace-or-append；未确认 K 线（confirm=0）实时刷新；REST 回填与 WS 增量在同一 actor 内合并，无竞态。
4. **交易走官方 CLI 而非自持密钥**：API Key 由 OKX 官方 `okx` CLI 的 `~/.okx/config.toml` 管理，MayStock 不接触、不存储任何私钥 —— 合规且边界干净。默认 demo（模拟盘），实盘需在设置中显式解锁 + 每单确认。
5. **Swift 6 工具链 + v5 语言模式**：并发注解按 v6 纪律书写（actor/@MainActor/Sendable），语言模式暂锁 v5 保证首编通过，后续可无痛升 v6。

## 3. 数据面（OKX，已核实 2026-07）

| 用途 | 通道/端点 | 说明 |
|------|-----------|------|
| 实时价 | WS `tickers` @ `wss://ws.okx.com:8443/ws/v5/public` | last/bid/ask/open24h/high24h/low24h/vol24h，~100ms-1s |
| K 线 | WS `candle{1m,5m,15m,1H,4H,1D,1W}` @ `wss://ws.okx.com:8443/ws/v5/business` | 9 字段数组，confirm 标志 |
| K 线回填 | REST `GET /api/v5/market/candles`（≤300, limit≤100 分页）/ `history-candles` | 启动与切周期时 |
| 深度 | WS `books5` @ public（5 档快照/100ms）+ 面板打开时 REST `GET /api/v5/market/books?sz=50` | 深度图用 50 档，实时买一卖一用 books5 |
| 标的元数据 | REST `GET /api/v5/public/instruments?instType=SPOT` | tickSz→小数位，添加标的时校验 |
| 心跳 | 空闲 18s 客户端发 `"ping"` → `"pong"` | 30s 无数据服务端断连 |
| 交易 | `okx` CLI（`npm i -g @okx_ai/okx-trade-cli`）：`okx spot place --instId … --json [--demo]`、`okx account balance --json` | 官方 Agent Trade Kit |

限频遵循：REST candles 20 req/2s，回填分页间隔 ≥120ms；UI 侧节流不影响推送接收。

## 4. 告警引擎

规则 = `(标的, 条件, 动作, 节律)`
- 条件：`价格上穿 X` / `价格下穿 X` / `24h 涨跌幅越过 ±X%` / `N 分钟内波动超 ±X%`（基于 sparkline 环形缓冲）
- 节律：一次性 / 触发后冷却 T 自动重挂；上/下穿带 0.05% 迟滞防抖
- 动作：系统通知（可带声音）· 菜单栏项闪烁 · 可选 shell hook（环境变量注入 `MAYSTOCK_INSTID/PRICE/RULE`，可直接串 `okx` CLI 实现「触价下单」）

## 5. 视觉语言

- 数字一律 `monospacedDigit`；涨 `systemGreen`、跌 `systemRed`，跟随深浅色模式
- 菜单栏 sparkline：22×(52~68)pt Retina 位图，首尾价决定色相，面积渐变填充，48~240 点
- 面板 360×340pt，`ultraThinMaterial` 背景，圆角 12，无标题栏；图表留白 8/12 栅格
- K 线：阳线空心可选/实心默认，MA20 橙色 1.2pt，最新价虚线 + 右侧价签胶囊
- 深度图：买绿卖红 25% 面积 + 1.5pt 描边，中价竖线，hover 读数（价格/累计量）
- 动效：面板 fade+2pt 位移 160ms ease-out；价格变动 120ms 色彩脉冲

## 6. 测试策略（端到端）

| 层 | 手段 | 跑在哪 |
|----|------|--------|
| 解码/合并/告警/格式化 | swift-testing 单测，真实抓包 fixture | `swift test`（Mac/Linux 均可） |
| TradeBridge | 假 `okx` 可执行桩（fixture 脚本）验证参数拼装与 JSON 解析 | `swift test` |
| **真实 E2E** | `maystock-e2e doctor`：REST 连通 → 回填 300 根 → 双 WS 订阅 → 收 ≥5 tick + ≥1 candle + book → 心跳往返 → 汇报延迟，非零退出码即失败 | `make e2e`（需外网） |
| 全链路 | `make verify` = build + test + e2e | 用户 Mac 一键 |
| UI 冒烟 | `Scripts/smoke-ui.sh`：装载 app、AppleScript 校验 status item 存在 | 用户 Mac |

## 7. 目录

```
Sources/MayStockKit/{Models,OKX,Engine,Trading,Util}
Sources/MayStock/{App,StatusBar,Panel,Charts,Settings,Support}
Sources/maystock-e2e/           # E2E 驱动 & 诊断 CLI
Tests/{MayStockKitTests,LiveE2ETests}
docs/{DESIGN.md,ICON_PROMPT.md}
Makefile · Scripts/
```

## 8. 非目标（v2.0 明确不做）

自绘 400 档增量深度合并（checksum）、多交易所聚合、组合持仓盈亏、WS 私有频道订单回报 —— 皆列入 v2.1 候选，不为赶功能牺牲优雅。

> v2.1 已落地其中的**组合持仓盈亏**（按策略归因，见 [STRATEGY.md](STRATEGY.md)），
> 并在其上补齐了策略导入、多窗口回测与仓位分配。其余三项仍为非目标。

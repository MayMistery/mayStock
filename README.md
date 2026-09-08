<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="MayStock">
</p>

<h1 align="center">MayStock 2.0</h1>

<p align="center">
  An elegant macOS menu bar market terminal: live prices, trends, charts,
  alerts and OKX CLI trading, in your menu bar.
</p>

<p align="center">
  <a href="README_CN.md">中文文档</a> ·
  <a href="docs/DESIGN.md">Design</a> ·
  <a href="https://github.com/MayMistery/mayStock/releases">Releases</a> ·
  MIT
</p>

---

## What it does

- **Menu bar, with trend** — each instrument renders as
  `₿ 118,234 ▲1.24% ▁▂▄▆▇` : monospaced price, colored 24h change, live
  sparkline (configurable window & style, per instrument).
- **Hover panel** — a non-activating panel (never steals focus) with
  candlesticks + MA20 + volume, tick-level line chart, 50-level market depth,
  crosshair readouts, 24h stats and bid/ask. Click the menu bar item to pin.
- **High-frequency data** — OKX v5 WebSockets (`tickers`/`books5` on
  `/public`, `candle*` on `/business`), ~100ms pushes, REST backfill of 300
  bars on launch and on interval switch, client-side `ping` keepalive,
  auto-reconnect with jittered backoff + resubscribe.
- **US equities, too** — the same watchlist holds tickers such as `TSLA`
  and `QQQ` alongside the pairs. Each venue has its own feed behind one
  `MarketFeed` port: stocks are read from Yahoo Finance's chart endpoint
  (no key; the interim source while the Schwab Trader API application is
  pending), quoted against the previous close with the session phase —
  pre-market, regular, after-hours, closed — on every surface, charted in
  New York time with closed hours collapsed, and refused a 4H bar their
  session cannot hold. The kernel's NYSE calendar keeps backtests honest
  about weekends and holidays.
- **Alerts** — price cross (with hysteresis), daily change thresholds (the
  trailing day on OKX, the session on a stock exchange),
  volatility within a window; system notifications, optional sound, optional
  shell hook (env vars let you chain the `okx` CLI: alert → order).
- **Terminal window** — one window with a sidebar: 总览 (account equity with
  its gap-aware curve, open positions, exchange balances, recent fills, every
  engine notice), 行情 (the watchlist at full size with the same charts as the
  panel, plus how each instrument shows in the menu bar), 策略, 告警,
  账户与连接 and 设置. The bar above every page shows which account is in
  play, whether it can be reached, and the emergency stop.
- **Strategy studio** — import a declarative strategy manifest (JSON) and get
  **1/7/30/90/365-day** backtests in one pass: return, drawdown, Sharpe,
  profit factor, and the buy-and-hold benchmark, plus a **robustness badge**
  built from sample size, out-of-sample decay and cross-window agreement.
  Numbers that cannot support a decision are labelled "insufficient sample"
  rather than presented as insight. Then allocate capital and start or stop
  trading. Manifests do arithmetic over candles — **no code is executed**.
- **Spot, perpetuals and options** — a manifest names its market; an
  `OPTION` strategy reads the underlying's candles and buys a call on a
  long signal or a put on a short one, never selling options. Backtests
  price contracts with Black–Scholes off realised volatility (and say so);
  live trading reads the exchange's chain and book and fills with IOC
  limits, with the contract chosen by the same rule the backtest used.
  Premiums are paid in the settlement coin (BTC); an account that holds
  none and cannot borrow it is refused before the order, with the shortfall
  spelled out.
- **Per-strategy attribution** — the exchange holds one balance, so every
  order carries a `clOrdId` strategy tag and is reconciled against
  `okx spot fills`. Each strategy's position, realised/unrealised P&L and
  return are therefore exact; anything that doesn't reconcile is shown as
  unattributed rather than quietly absorbed. The hover panel shows positions
  and returns only — there is no manual order entry.
- **Trading** — via OKX's official CLI (Agent Trade Kit). Demo mode by
  default; live trading requires an explicit unlock *and* per-strategy
  confirmation. **Demo and live are separate accounts with separate API
  keys**, so each environment has its own CLI profile; switching verifies the
  target account (a read-only balance call), explains what will stop, and
  restarts the trading loop across the boundary so nothing decided under one
  account executes on the other. MayStock never touches your API keys.
  **Backtests need no credentials at all — they read public market data.**
- **Research bench** (`maystock-lab`) — grid optimisation, **walk-forward
  validation**, portfolio backtests with leg correlation, and OKX fee-tier
  modelling (defaults to regular Lv1; `--sync` pulls your account's real
  rates). Optimisation always reports the Sharpe the luckiest of N trials
  would reach with *no edge at all*, so a curve-fit cannot pose as a
  discovery. Ships 20 declarable signal sources (Fear & Greed, on-chain,
  DXY/VIX/treasuries, Coinbase premium — all free, no key, up to 65 years of
  history) plus an `ic` command that scores them with overlap and
  multiple-testing corrections. See [docs/STRATEGY-DEV.md](docs/STRATEGY-DEV.md).
- **Watchlist** — any OKX spot/perp instrument, validated against the
  exchange when added. BTC-USDT out of the box.
- **Intelligence station** — a terminal calendar covering seven days back and
  thirty days ahead, with daily macro reports, hourly geopolitical updates,
  and a news check every thirty minutes. Claude Agent SDK uses exactly
  `model_hub/es1_orange_o50[1m]`. Flash reports require verified event occurrence
  times and are silent when no eligible new event exists. Every watched
  instrument receives an evidence-linked directional assessment or an explicit
  insufficient-evidence result. Run `./Scripts/setup-intelligence.sh` and
  configure Claude access to the requested model first. Defaults: daily at
  08:00 Asia/Taipei, 1-hour forecast horizon. The app must be running and the
  computer awake; waking checks the current window. See [setup and verification](docs/INTELLIGENCE.md).

```bash
./Scripts/new-strategy.sh "My ETH trend" trend ETH-USDT 4H   # scaffold, backtest, walk-forward
make lab ARGS="walkforward 01-btc-ema-trend --folds 4"
make lab ARGS="portfolio 01-btc-ema-trend eth-4h-breakout --weights 0.5,0.5 --capital 30000"
```

## Install From Release

1. Download `MayStock-v2.0.0-macos.zip` from
   [GitHub Releases](https://github.com/MayMistery/mayStock/releases).
2. Unzip it and move `MayStock.app` to `/Applications`.
3. Launch MayStock. It runs as a menu bar app, so no Dock icon is shown.

## Build From Source

```bash
git clone https://github.com/MayMistery/mayStock.git
cd mayStock
./Scripts/make.sh run   # build -> /Applications/MayStock.app -> launch
```

The Makefile delegates to the same script, so `make run` works too. Requires
macOS 15+ and a Swift 6 toolchain. The current release is verified with Apple
Swift 6.3.2 Command Line Tools. With the macOS 27 SDK the Command Line Tools
lack the SwiftUI macro plugin, so the build script also looks for one in an
installed Xcode; `swift build` on its own needs `-Xswiftc -plugin-path` there.

Optional trading support:

```bash
npm install -g @okx_ai/okx-trade-cli
okx config   # store API keys with the official CLI, not with MayStock
```

## Verify (end-to-end)

```bash
./Scripts/make.sh verify   # release build + unit tests + live OKX E2E
```

`maystock-e2e doctor` exercises the exact production code paths: REST
ticker/metadata/backfill, both WebSockets, live ticks/candles/depth, and
REST/WS price coherence. `okx` CLI detection is reported separately; trading
stays hidden in the app until the optional CLI is installed.

```bash
./Scripts/make.sh snapshot   # draw the panel and every terminal page to dist/snapshots/*.png
```

A menu bar accessory has no window to screenshot, so the app can render its
own surfaces: against a *copy* of the state directory, with the trading loop
off, into real off-screen windows. That is how a layout change gets looked
at before it ships.

## Architecture

```
MayStockKit   (pure Foundation, Linux-compilable)
  Models/  OKX/  Engine/  Trading/  Util/
MayStock      (AppKit + SwiftUI menu bar app)
  App/  StatusBar/  Panel/  Charts/  Terminal/  Design/  Support/
maystock-e2e  (E2E driver & diagnostics CLI)
Tests/MayStockKitTests   (swift-testing, fixture-driven)
```

See [docs/DESIGN.md](docs/DESIGN.md) for the full design and the 1.x
post-mortem. App icon: generate with [docs/ICON_PROMPT.md](docs/ICON_PROMPT.md).

## License

[MIT](LICENSE)

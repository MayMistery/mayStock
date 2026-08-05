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
- **Alerts** — price cross (with hysteresis), 24h change thresholds,
  volatility within a window; system notifications, optional sound, optional
  shell hook (env vars let you chain the `okx` CLI: alert → order).
- **Strategy studio** — import a declarative strategy manifest (JSON) and get
  **1/7/30/90/365-day** backtests in one pass: return, drawdown, Sharpe,
  profit factor, and the buy-and-hold benchmark, plus a **robustness badge**
  built from sample size, out-of-sample decay and cross-window agreement.
  Numbers that cannot support a decision are labelled "insufficient sample"
  rather than presented as insight. Then allocate capital and start or stop
  trading. Manifests do arithmetic over candles — **no code is executed**.
- **Per-strategy attribution** — the exchange holds one balance, so every
  order carries a `clOrdId` strategy tag and is reconciled against
  `okx spot fills`. Each strategy's position, realised/unrealised P&L and
  return are therefore exact; anything that doesn't reconcile is shown as
  unattributed rather than quietly absorbed. The hover panel shows positions
  and returns only — there is no manual order entry.
- **Trading** — via OKX's official CLI (Agent Trade Kit). Demo mode by
  default; live trading requires an explicit unlock *and* per-strategy
  confirmation. MayStock never touches your API keys. **Backtests need no
  credentials at all — they read public market data.**
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
Swift 6.3.2 Command Line Tools.

Optional trading support:

```bash
npm install -g @okx_ai/okx-trade-cli
okx config   # store API keys with the official CLI, not with MayStock
```

## Verify (end-to-end)

```bash
./Scripts/make.sh verify   # release build + 32 unit tests + live OKX E2E
```

`maystock-e2e doctor` exercises the exact production code paths: REST
ticker/metadata/backfill, both WebSockets, live ticks/candles/depth, and
REST/WS price coherence. `okx` CLI detection is reported separately; trading
stays hidden in the app until the optional CLI is installed.

## Architecture

```
MayStockKit   (pure Foundation, Linux-compilable)
  Models/  OKX/  Engine/  Trading/  Util/
MayStock      (AppKit + SwiftUI menu bar app)
  App/  StatusBar/  Panel/  Charts/  Settings/  Support/
maystock-e2e  (E2E driver & diagnostics CLI)
Tests/MayStockKitTests   (swift-testing, fixture-driven)
```

See [docs/DESIGN.md](docs/DESIGN.md) for the full design and the 1.x
post-mortem. App icon: generate with [docs/ICON_PROMPT.md](docs/ICON_PROMPT.md).

## License

[MIT](LICENSE)

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
- **Trading** — via OKX's official CLI (Agent Trade Kit). Demo mode by
  default; live trading requires an explicit unlock *and* per-order
  confirmation. MayStock never touches your API keys.
- **Watchlist** — any OKX spot/perp instrument, validated against the
  exchange when added. BTC-USDT out of the box.

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

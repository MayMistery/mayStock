# MayStock — macOS Menu Bar Monitor

## Overview

A macOS 26+ menu bar application that displays real-time system metrics (CPU/Memory/Network) and cryptocurrency prices (starting with BTC/USDT from OKX). The menu bar shows concise text indicators; hovering reveals a Popover panel with rich financial charts. Configuration is managed through a full Settings window opened via right-click.

## Tech Stack

- **Language**: Swift 6
- **UI Framework**: SwiftUI (macOS 26+, Liquid Glass)
- **Menu Bar**: `MenuBarExtra` with `.window` style
- **Charts**: Swift Charts + custom drawing for K-line and Depth charts
- **Networking**: URLSessionWebSocketTask for OKX WebSocket API
- **System Monitoring**: Third-party Swift library (SystemKit or similar)
- **Persistence**: `@AppStorage` + Codable JSON files
- **Testing**: XCTest (unit/integration) + XCUITest (E2E)
- **Min Deployment**: macOS 26.0 (Tahoe)

## Architecture

```
mayStock.app
├── MayStockApp.swift              — App entry, MenuBarExtra declaration
├── Features/
│   ├── MenuBar/
│   │   ├── MenuBarView.swift      — Text indicator rendering
│   │   └── MenuBarViewModel.swift — Aggregates all monitor data
│   ├── Popover/
│   │   ├── PopoverView.swift      — Chart container with tab switching
│   │   └── ChartSelector.swift    — Chart type / time span picker
│   ├── Charts/
│   │   ├── CandlestickChartView.swift  — K-line (OHLC)
│   │   ├── DepthChartView.swift        — Order book depth
│   │   ├── VolumeChartView.swift       — Volume bars
│   │   └── LineChartView.swift         — Line chart (system + price)
│   └── Settings/
│       ├── SettingsWindow.swift    — Main settings container
│       ├── MonitorItemEditor.swift — Add/edit monitor items
│       ├── ChartConfigEditor.swift — Chart type, time span, style
│       └── GeneralSettings.swift   — Launch at login, appearance, etc.
├── Services/
│   ├── MarketData/
│   │   ├── OKXWebSocketService.swift   — WebSocket connection management
│   │   ├── OKXMessageParser.swift      — Parse ticker/kline/depth messages
│   │   └── MarketDataProvider.swift    — Protocol + unified data interface
│   ├── SystemMonitor/
│   │   ├── CPUMonitor.swift
│   │   ├── MemoryMonitor.swift
│   │   └── NetworkMonitor.swift
│   └── Configuration/
│       └── ConfigurationService.swift  — Load/save/observe config changes
├── Models/
│   ├── MonitorItem.swift          — What to monitor (type, source, display name)
│   ├── ChartConfig.swift          — Chart type, time span (1s–7d), visual style
│   ├── MarketTick.swift           — Price tick (timestamp, price, volume)
│   ├── OHLC.swift                 — Candlestick data point
│   └── OrderBookEntry.swift       — Depth data (price, quantity, side)
└── Tests/
    ├── UnitTests/
    │   ├── OKXMessageParserTests.swift
    │   ├── MarketDataProviderTests.swift
    │   ├── SystemMonitorTests.swift
    │   └── ConfigurationServiceTests.swift
    ├── IntegrationTests/
    │   ├── OKXWebSocketIntegrationTests.swift
    │   └── DataFlowIntegrationTests.swift
    └── UITests/
        ├── MenuBarUITests.swift
        ├── PopoverChartUITests.swift
        └── SettingsUITests.swift
```

## Menu Bar Display

- Shows configured items separated by ` | `: `CPU 12% | MEM 8.2G | BTC 62213.45`
- Each item: optional short label (user-configurable abbreviation) + current value
- Text uses SF Mono for numbers, system font for labels
- Color coding: green for positive trend, red for negative (subtle, not garish)
- Truncation: if too many items, show first N with `…` indicator

## Popover Panel (Hover)

- Triggered on mouse hover over menu bar item (using NSEvent monitoring)
- Liquid Glass material background
- Contains:
  - Header: asset name, current price, 24h change percentage
  - Chart area: renders the configured chart type
  - Time span selector: pills for 1s / 5s / 1m / 5m / 15m / 1h / 4h / 1d / 7d
  - Chart type switcher: icons for line / candlestick / depth / volume
- Size: approximately 400x300pt, adapts to content
- Dismisses when mouse leaves the popover area

## Charts

### Candlestick (K-line)
- Custom SwiftUI Canvas drawing (Swift Charts doesn't support candlesticks natively)
- Green body for bullish, red for bearish
- Wicks/shadows rendered as thin lines
- X-axis: time labels based on selected span
- Y-axis: price with auto-scaling

### Depth Chart
- Area chart showing cumulative bid/ask order book
- Green area = bids (left), Red area = asks (right)
- Mid-price line in center
- Data source: OKX order book WebSocket channel

### Volume Chart
- Bar chart below candlestick or standalone
- Color matches candle direction (green/red)
- Uses Swift Charts `BarMark`

### Line Chart
- Smooth bezier curve for price or system metrics
- Gradient fill below the line
- Uses Swift Charts `LineMark` with interpolation

## Data Sources

### OKX WebSocket API
- **Endpoint**: `wss://ws.okx.com:8443/ws/v5/public`
- **Channels**:
  - `tickers` — real-time price updates
  - `candle{period}` — K-line data (1s, 1m, 5m, 15m, 1H, 4H, 1D)
  - `books5` / `books` — order book depth
  - `trades` — individual trades for volume
- **Reconnection**: exponential backoff on disconnect, max 5 retries then surface error
- **Rate limits**: respect OKX connection limits (3 connections per IP for public)

### System Monitoring
- **CPU**: via third-party lib wrapping `host_processor_info` / `host_statistics`
- **Memory**: physical memory used/total, swap usage
- **Network**: bytes in/out per second across all active interfaces
- **Sampling interval**: configurable, default 2 seconds

## Configuration

### MonitorItem
```swift
struct MonitorItem: Codable, Identifiable {
    let id: UUID
    var type: MonitorType          // .crypto, .cpu, .memory, .network
    var label: String              // Display abbreviation ("BTC", "CPU")
    var source: DataSource         // .okx(instId: "BTC-USDT"), .system
    var chartConfig: ChartConfig
    var isEnabled: Bool
    var sortOrder: Int
}
```

### ChartConfig
```swift
struct ChartConfig: Codable {
    var chartType: ChartType       // .line, .candlestick, .depth, .volume
    var timeSpan: TimeSpan         // .seconds(1), .minutes(5), .hours(4), .days(7)
    var showVolume: Bool           // overlay volume bars
    var colorScheme: ChartColorScheme  // .standard, .monochrome, .custom
}
```

### Persistence
- Stored as JSON in `~/Library/Application Support/MayStock/config.json`
- Observable via `ConfigurationService` using Combine/AsyncSequence
- Migration support for future schema changes (version field in JSON)

## Settings Window

Opened via right-click on menu bar item → "Settings…"

- **General tab**: Launch at login, menu bar item limit, update intervals
- **Monitors tab**: List of configured items, add/remove/reorder, edit each item's label/source/chart
- **Appearance tab**: Color scheme preferences, font size, chart style presets
- **About tab**: Version, icon prompt credit, links

## Error Handling

- WebSocket disconnection: show "·" or "—" in menu bar for affected items, auto-reconnect
- Invalid data: skip malformed messages, log warning, don't crash
- No network: graceful degradation, system monitors continue working
- Configuration corruption: fall back to defaults, surface one-time alert

## Testing Strategy

### Unit Tests
- OKX message parsing (valid JSON, malformed, edge cases)
- Chart data computation (OHLC aggregation, depth accumulation)
- Configuration serialization/deserialization
- System monitor value formatting

### Integration Tests
- OKX WebSocket connection lifecycle (connect, subscribe, receive, disconnect)
- Data flow: WebSocket message → parsed model → ViewModel update
- Configuration change → immediate UI reflection

### E2E (XCUITest)
- App launches with menu bar item visible
- Hover triggers popover with chart content
- Right-click opens settings window
- Add/remove monitor item persists across restart
- Chart type switching renders correct chart

## Icon

Not generated programmatically. Prompt for external generation:

> A minimal, elegant macOS app icon for a financial/system monitoring tool. A translucent glass cube or crystal prism refracting a subtle upward-trending candlestick chart line in emerald green and electric blue gradients. The background is a deep matte black with a faint circular glow. Apple macOS Big Sur / Tahoe icon style with rounded squircle shape, soft ambient lighting, volumetric glass material, no text, no busy details — just one pristine geometric form that whispers "real-time data elegance." 1024x1024, centered composition.

## Scope — MVP (this spec)

- BTC/USDT from OKX only (single trading pair)
- CPU + Memory + Network system monitors
- All four chart types in Popover
- Full settings window
- E2E test coverage
- macOS 26+ only
- No multi-window, no notifications, no alerts

## Out of Scope (future)

- Multiple crypto pairs / exchanges
- Stock market data (A-shares, US stocks)
- Price alerts / notifications
- Widget / Lock Screen integration
- Export data / screenshots
- iCloud sync of configuration

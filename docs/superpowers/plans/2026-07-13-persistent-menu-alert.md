# Persistent Menu Bar Alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent red scan-line state to the affected MayStock menu bar item when an alert fires, clearing all accumulated alerts for that instrument on left click while preserving the existing panel interaction.

**Architecture:** A new AppKit-free `AlertAttentionState` in `MayStockKit` owns runtime-only pending counts keyed by instrument ID. `AppState` marks the state from the existing alert callback, and `StatusItemController` observes it to render a red dot, red text, tooltip count, and Core Animation scan line; left-click acknowledgement mutates the shared state before the existing panel toggle.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, Swift Observation, swift-testing, AppKit, QuartzCore/Core Animation, macOS 15+

## Global Constraints

- Keep existing macOS notifications, optional sounds, and shell hooks unchanged.
- Use visual direction B: a solid red dot, system-red item text, and a 2 pt red scan line along the bottom of the affected status item.
- Use one 1.05-second ease-in/ease-out autoreversing animation group: horizontal scale 0.55 to 1.0 and opacity 0.45 to 1.0.
- Keep attention state in memory only; do not write it to `AppConfig` or another persisted store.
- Accumulate a pending count per instrument; one left click clears the complete count for that instrument and then preserves the existing panel toggle behavior.
- Right click must keep pending state and only open the existing context menu.
- Rebuilding or reordering status items must not clear pending state.
- With macOS Reduce Motion enabled, show the red dot, red text, and static red line without animation.
- Do not add dependencies, notification actions, repeated sounds, a history window, or alert-rule evaluation changes.

---

### Task 1: Runtime Alert Attention State

**Files:**
- Create: `Sources/MayStockKit/Engine/AlertAttentionState.swift`
- Create: `Tests/MayStockKitTests/AlertAttentionStateTests.swift`

**Interfaces:**
- Consumes: instrument IDs from `AlertEvent.rule.instId`.
- Produces: `AlertAttentionState.markPending(for:)`, `acknowledgeAll(for:)`, `pendingCount(for:)`, and `isPending(for:)` for Task 2.

- [ ] **Step 1: Write the failing attention-state tests**

Create `Tests/MayStockKitTests/AlertAttentionStateTests.swift`:

```swift
import Testing
@testable import MayStockKit

@Suite("Alert attention state")
@MainActor
struct AlertAttentionStateTests {
    @Test func firstAlertCreatesPendingState() {
        let state = AlertAttentionState()

        state.markPending(for: "BTC-USDT")

        #expect(state.isPending(for: "BTC-USDT"))
        #expect(state.pendingCount(for: "BTC-USDT") == 1)
    }

    @Test func repeatedAlertsIncrementOnlyTheirInstrument() {
        let state = AlertAttentionState()

        state.markPending(for: "BTC-USDT")
        state.markPending(for: "BTC-USDT")
        state.markPending(for: "ETH-USDT")

        #expect(state.pendingCount(for: "BTC-USDT") == 2)
        #expect(state.pendingCount(for: "ETH-USDT") == 1)
    }

    @Test func acknowledgementClearsOnlyTheTargetInstrument() {
        let state = AlertAttentionState()
        state.markPending(for: "BTC-USDT")
        state.markPending(for: "BTC-USDT")
        state.markPending(for: "ETH-USDT")

        state.acknowledgeAll(for: "BTC-USDT")

        #expect(!state.isPending(for: "BTC-USDT"))
        #expect(state.pendingCount(for: "BTC-USDT") == 0)
        #expect(state.pendingCount(for: "ETH-USDT") == 1)
    }

    @Test func acknowledgementIsIdempotent() {
        let state = AlertAttentionState()

        state.acknowledgeAll(for: "BTC-USDT")
        state.acknowledgeAll(for: "BTC-USDT")

        #expect(state.pendingCount(for: "BTC-USDT") == 0)
    }

    @Test func alertAfterAcknowledgementCreatesNewPendingState() {
        let state = AlertAttentionState()
        state.markPending(for: "BTC-USDT")
        state.acknowledgeAll(for: "BTC-USDT")

        state.markPending(for: "BTC-USDT")

        #expect(state.isPending(for: "BTC-USDT"))
        #expect(state.pendingCount(for: "BTC-USDT") == 1)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter AlertAttentionStateTests
```

Expected: compilation fails because `AlertAttentionState` is not defined.

- [ ] **Step 3: Implement the minimal runtime state**

Create `Sources/MayStockKit/Engine/AlertAttentionState.swift`:

```swift
import Observation

/// Runtime-only acknowledgement state for fired alerts, grouped by instrument.
@Observable
@MainActor
public final class AlertAttentionState {
    private var pendingCounts: [String: Int] = [:]

    public init() {}

    public func markPending(for instId: String) {
        pendingCounts[instId, default: 0] += 1
    }

    public func acknowledgeAll(for instId: String) {
        pendingCounts.removeValue(forKey: instId)
    }

    public func pendingCount(for instId: String) -> Int {
        pendingCounts[instId, default: 0]
    }

    public func isPending(for instId: String) -> Bool {
        pendingCount(for: instId) > 0
    }
}
```

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run:

```bash
swift test --filter AlertAttentionStateTests
swift test
```

Expected: all five focused tests and the full MayStockKit suite pass with zero failures.

- [ ] **Step 5: Review and commit Task 1**

Check:

```bash
git diff --check
git status --short
```

Then commit only the Task 1 files:

```bash
git add Sources/MayStockKit/Engine/AlertAttentionState.swift Tests/MayStockKitTests/AlertAttentionStateTests.swift
git commit -m "feat: track pending alert attention"
```

---

### Task 2: App Alert Wiring and Red Status-Item Scan Line

**Files:**
- Modify: `Sources/MayStock/App/AppState.swift`
- Modify: `Sources/MayStock/StatusBar/StatusItemController.swift`

**Interfaces:**
- Consumes: Task 1's public `AlertAttentionState` API.
- Produces: alert callback wiring, observation-driven status-item styling, Reduce Motion fallback, pending tooltip count, and left-click acknowledgement.

- [ ] **Step 1: Wire fired alerts into the shared attention state**

In `AppState`, add the property beside `alerts` and `notifications`:

```swift
let alertAttention: AlertAttentionState
```

Initialize it immediately after `alerts = AlertEngine()`:

```swift
alertAttention = AlertAttentionState()
```

At the start of the existing `alerts.onAlert` closure, before notification delivery, add:

```swift
self.alertAttention.markPending(for: event.rule.instId)
```

Do not change notification, sound, or shell-hook delivery.

- [ ] **Step 2: Add the scan-line layer and left-click acknowledgement**

In `StatusItemController.swift`, add:

```swift
import QuartzCore
```

Add one reusable layer property:

```swift
private let alertScanLayer = CAGradientLayer()
private static let alertAnimationKey = "maystock.alert.scan"
```

At the end of `configureButton()`, after installing the tracking area, configure the layer:

```swift
button.wantsLayer = true
alertScanLayer.colors = [
    NSColor.clear.cgColor,
    NSColor.systemRed.cgColor,
    NSColor.clear.cgColor,
]
alertScanLayer.locations = [0, 0.5, 1]
alertScanLayer.startPoint = CGPoint(x: 0, y: 0.5)
alertScanLayer.endPoint = CGPoint(x: 1, y: 0.5)
alertScanLayer.cornerRadius = 1
alertScanLayer.isHidden = true
button.layer?.addSublayer(alertScanLayer)
```

Update the left-click path in `handleClick()` so acknowledgement happens before the existing panel toggle:

```swift
} else {
    hoverWorkItem?.cancel()
    if appState.alertAttention.isPending(for: watchItem.instId) {
        appState.alertAttention.acknowledgeAll(for: watchItem.instId)
        scheduleRender(force: true)
    }
    appState.panel.togglePinned(instId: watchItem.instId, anchoredTo: statusItem)
}
```

Leave the right-click path unchanged.

- [ ] **Step 3: Render the selected B visual state**

In `render()`, observe the pending count with the existing ticker/session reads:

```swift
let pendingCount = appState.alertAttention.pendingCount(for: watchItem.instId)
let isAlerting = pendingCount > 0
let alertColor: NSColor? = isAlerting ? .systemRed : nil
```

Before the existing leading glyph/label block, add the red dot:

```swift
if isAlerting {
    title.append(NSAttributedString(string: "● ", attributes: [
        .font: smallFont,
        .foregroundColor: NSColor.systemRed,
    ]))
}
```

For every existing `.foregroundColor` in the title construction, use the alert color when it exists. Preserve the current normal colors as fallbacks. The four forms are:

```swift
.foregroundColor: alertColor ?? NSColor.secondaryLabelColor
.foregroundColor: alertColor ?? NSColor.labelColor
.foregroundColor: alertColor ?? (up ? NSColor.systemGreen : NSColor.systemRed)
.foregroundColor: alertColor ?? NSColor.tertiaryLabelColor
```

After setting the sparkline image and before assigning the tooltip, call:

```swift
updateAlertIndicator(isAlerting: isAlerting)
```

Change the tooltip call and helper signature to receive `pendingCount`. Prefix the existing market tooltip when pending:

```swift
button.toolTip = toolTip(
    ticker: ticker, connection: connection, pendingCount: pendingCount)
```

```swift
private func toolTip(
    ticker: Ticker?,
    connection: OKXConnectionState,
    pendingCount: Int
) -> String {
    let alertPrefix = pendingCount > 0
        ? "\(pendingCount) 条告警待确认 · 点击确认并打开面板\n"
        : ""
    guard let ticker else {
        return alertPrefix + "\(watchItem.instId) — 连接中 (\(connection.rawValue))"
    }
    return alertPrefix + """
    \(watchItem.instId) · OKX
    最新 \(PriceFormatter.auto(ticker.last))   24h \(PriceFormatter.signedPercent(ticker.changePct24h))
    高 \(PriceFormatter.auto(ticker.high24h))   低 \(PriceFormatter.auto(ticker.low24h))
    """
}
```

- [ ] **Step 4: Implement stable Core Animation and Reduce Motion fallback**

Add these helpers to `StatusItemController`:

```swift
private func updateAlertIndicator(isAlerting: Bool) {
    guard let button = statusItem.button else { return }
    button.layoutSubtreeIfNeeded()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    alertScanLayer.frame = CGRect(
        x: 3,
        y: 1,
        width: max(0, button.bounds.width - 6),
        height: 2)
    alertScanLayer.isHidden = !isAlerting
    alertScanLayer.opacity = 1
    CATransaction.commit()

    guard isAlerting else {
        alertScanLayer.removeAnimation(forKey: Self.alertAnimationKey)
        return
    }

    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        alertScanLayer.removeAnimation(forKey: Self.alertAnimationKey)
    } else if alertScanLayer.animation(forKey: Self.alertAnimationKey) == nil {
        alertScanLayer.add(makeAlertAnimation(), forKey: Self.alertAnimationKey)
    }
}

private func makeAlertAnimation() -> CAAnimationGroup {
    let scale = CABasicAnimation(keyPath: "transform.scale.x")
    scale.fromValue = 0.55
    scale.toValue = 1.0

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0.45
    opacity.toValue = 1.0

    let group = CAAnimationGroup()
    group.animations = [scale, opacity]
    group.duration = 1.05
    group.autoreverses = true
    group.repeatCount = .infinity
    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    return group
}
```

Also remove the animation from `remove()` before removing the status item:

```swift
alertScanLayer.removeAllAnimations()
```

- [ ] **Step 5: Verify the integrated app**

Run:

```bash
swift test
swift build
./Scripts/make.sh verify
```

Expected: all unit tests pass, both package targets compile, and the repository verification script exits zero. If live network verification is unavailable, record the exact failing command and output while still requiring `swift test` and `swift build` to pass.

Inspect the diff for the required interaction boundaries:

```bash
git diff --check
git diff -- Sources/MayStock/App/AppState.swift Sources/MayStock/StatusBar/StatusItemController.swift
```

Confirm from the code that the right-click branch does not call `acknowledgeAll`, the left-click branch calls it before `togglePinned`, and the animation is installed only when the keyed animation is absent.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/MayStock/App/AppState.swift Sources/MayStock/StatusBar/StatusItemController.swift
git commit -m "feat: pulse menu bar for pending alerts"
```

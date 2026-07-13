# MayStock Persistent Menu Bar Alert Design

## Goal

Make a fired market alert difficult to miss without replacing the existing macOS notification flow or interrupting normal work.

The selected visual direction is **B: red scan line**. The affected instrument's menu bar item keeps its normal footprint while showing a red status dot, red text, and a pulsing red line along its lower edge. The state remains visible until the user acknowledges it.

## User-visible behavior

1. A rule fires through the existing `AlertEngine` path.
2. MayStock continues to send the configured macOS notification and optional sound, then marks that instrument as needing attention.
3. Every menu bar item for that instrument enters the alert style:
   - a small solid red dot before the existing content;
   - the item's text changes to system red;
   - a 2 pt red line along the bottom expands and fades in a slow, repeating pulse.
4. Additional alerts for the same instrument increase its pending count but do not stack animations or change the pulse frequency.
5. The tooltip shows the pending count and tells the user that clicking will acknowledge the alerts and open the market panel.
6. A left click acknowledges all currently pending alerts for that instrument, removes the alert style immediately, and then runs the existing click behavior to open or pin the panel.
7. A right click only opens the context menu. It does not acknowledge alerts.
8. Any alert fired after acknowledgement starts a new pending state.

Pending attention is runtime state. It is not written to `AppConfig`, so restarting MayStock does not resurrect stale alerts.

## State model

Add a small `AlertAttentionState` type to `MayStockKit`:

```swift
@Observable
@MainActor
public final class AlertAttentionState {
    public func markPending(for instId: String)
    public func acknowledgeAll(for instId: String)
    public func pendingCount(for instId: String) -> Int
    public func isPending(for instId: String) -> Bool
}
```

The state owns an in-memory `[String: Int]` count keyed by instrument ID. It has no dependency on AppKit, notifications, configuration, or status items, so its acknowledgement semantics can be unit tested independently.

`AppState` owns one instance for the application lifetime. Its existing `alerts.onAlert` callback marks the event's instrument pending before delivering the system notification and shell hook.

## Menu bar rendering

`StatusItemController` reads `AlertAttentionState` in its existing observation-driven `render()` path. This keeps the alert style synchronized even when a status item is recreated after watchlist changes.

The dot is part of the attributed title. When pending, all rendered title segments use `NSColor.systemRed`; normal market up/down coloring resumes after acknowledgement.

The scan line is a dedicated `CALayer` attached to the status button. Starting an alert installs one pair of repeating Core Animation animations:

- horizontal scale from 0.55 to 1.0 and back;
- opacity from 0.45 to 1.0 and back;
- duration 1.05 seconds with an ease-in/ease-out timing curve.

Subsequent price renders update the layer frame but do not restart the animation. Acknowledgement removes the animation and hides the layer.

When macOS Reduce Motion is enabled, the underline remains steadily red instead of animating. The red dot and text preserve the alert signal without motion.

## Click and acknowledgement flow

`StatusItemController.handleClick()` keeps the current event split:

- right mouse up: show the context menu and retain pending state;
- left mouse up: if pending, call `acknowledgeAll(for:)`, then call the existing `panel.togglePinned(...)` behavior.

Acknowledgement happens before opening the panel, so the visual response to the click is immediate. A new alert arriving afterward is a new state and must not be cleared by the earlier click.

## Failure handling and boundaries

- System notification denial or Focus mode does not affect the in-app menu bar signal.
- If an alert fires for an instrument with no enabled status item, the pending count remains in memory. If the item is enabled later in the same run, it renders as pending.
- Multiple watchlist items for the same instrument share acknowledgement through the instrument key.
- Removing or rebuilding a status item does not clear pending state.
- This change does not add notification actions, persistence, a history window, repeated sounds, or changes to alert rule evaluation.

## Tests and verification

Unit tests for `AlertAttentionState` cover:

- first alert creates one pending item;
- repeated alerts increment the count for the same instrument;
- instruments remain isolated;
- one acknowledgement clears the complete count for one instrument;
- acknowledgement is idempotent and does not clear other instruments;
- a new alert after acknowledgement creates pending state again.

App verification covers:

- `swift test` for the state and existing alert engine regression suite;
- `swift build` for AppKit/Core Animation compilation;
- existing `Scripts/make.sh verify` checks when network E2E is available;
- a local UI smoke run confirming the red scan line persists, does not restart on price updates, left-click clears it and opens the panel, and right-click preserves it.

## Acceptance criteria

- A fired alert produces a persistent red menu bar signal for the correct instrument even when the system notification is not visible.
- The signal stays active across price ticks and repeated alerts until a left click.
- One left click clears all accumulated alerts for that instrument and preserves the existing panel behavior.
- Right click does not clear the signal.
- A later alert can activate the signal again.
- Reduce Motion users receive an equally clear static red indicator.

# CODEX.md — Commander Tabbington

This file captures short-term state and context for returning to this repo.

## Current working state
- Uncommitted changes: `CommanderTabbington/Services/Input/InputListener.swift`
- Last edits focused on input robustness under load and command-release watchdogs.

## Recent functional changes (high signal)
- InputListener:
  - Added DispatchSourceTimer-based command-release poller on a background queue (more resilient under UI stalls).
  - Added a command-release watchdog that commits selection after 250ms of Command being up.
  - Watchdog state now resets on any keyDown while Command is held (heartbeat).
  - When the event tap is disabled (timeout/user input), cancel selection and stop pollers.
- AppState:
  - Added a command-release watchdog that commits selection after 250ms of Command being up, used when switcher is visible.
- Permissions:
  - Custom permissions window guides Accessibility permission; auto-relaunch once granted.
  - Runtime loss of Accessibility triggers alert and app exit (to avoid system input issues).
  - Loss monitor starts only after initial permissions check passes.
- UI polish:
  - Switcher overlay now has rounded corners via clip shape.
  - Badge circle slightly larger; font sizes slightly reduced; digits centered with monospaced digits.
  - "999+" special-cased to use smaller font size.

## Input-handling design notes
- System switcher suppression relies on a HID or session event tap; if taps are blocked or disabled, Cmd+Tab may fall through.
- Watchdogs exist in both InputListener and AppState:
  - InputListener watchdog acts even if UI never becomes visible.
  - AppState watchdog acts only while the overlay is visible.
- On tap-disabled events, InputListener now cancels pending/visible switcher state.

## MRU ordering notes
- AppRecents/WindowRecents no longer seed from full window list at startup; initial ordering uses CGWindowList fallbacks:
  1) on-screen list first, then
  2) full window list for remaining items, then
  3) name tiebreaker.
- Tier grouping is performed after sorting to preserve MRU within each tier.
- Active app can override hidden/minimized exclusion (keeps the active app selectable).

## Permissions notes
- Accessibility permission changes typically require restart; the app auto-relaunches after granting.
- Input Monitoring is best-effort; if event taps fail, an Input Monitoring alert is shown with a deep link.

## Files touched recently
- `CommanderTabbington/Services/Input/InputListener.swift` (watchdogs, pollers, tap-disabled bailout)
- `CommanderTabbington/App/AppState.swift` (command-release watchdog)
- `CommanderTabbington/App/AppDelegate.swift` (accessibility loss monitor)
- `CommanderTabbington/UI/AppCardView.swift` (badge sizing/centering)
- `CommanderTabbington/UI/SwitcherView.swift` (rounded corners)
- `CommanderTabbington/Domain/Recents/AppRecents.swift`, `CommanderTabbington/Domain/Recents/WindowRecents.swift`
- `CommanderTabbington/Services/System/WindowManager.swift`

## Testing notes
- Stress the system (heavy load) and verify:
  - Tabbington overlay appears reliably.
  - System switcher does not appear alongside Tabbington.
  - Releasing Command commits selection and closes overlay.
- Revoke Accessibility while running:
  - App should show alert and quit cleanly.

## Open questions / follow-ups
- None currently; verify that dual watchdogs do not double-commit under edge timing.

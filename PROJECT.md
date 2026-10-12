# Project: Watchdog Main Thread Fix

## Architecture
- **Layer 0 (`MCACore`)**: Foundation models, value types (`ScreenLook`, `ActionApprovalRequest`, `ActionApprovalStatus`).
- **Layer 1 (`MCASensing`)**: Low-level screen capture (`ScreenCapturer`), accessibility reading (`AccessibilityReader`), image fingerprinting (`FrameFingerprint`).
- **Layer 2 (`MCAPerception`)**: OCR and text recognition (`TextRecognizer`).
- **Layer 6 (`MCAPresentation`)**: User interface, chat windows (`ChatWindow`), SwiftUI views (`ChatView`), HUD state (`HUDState`).
- **Application (`mca`)**: Composition root, periodic screen observation coordinator (`ScreenWatcher`), application coordinator (`Copilot`), tool approval helper (`ToolApprovalUI`), health monitor (`MainThreadWatchdog`).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Non-Blocking AX Tree Traversal | Add messaging timeout and background execution for `AccessibilityReader` | M1 | Survey R1 |
| 2 | Background Image Fingerprinting | Compute `FrameFingerprint` in background tasks off `@MainActor` | M1 | Survey R1 |
| 3 | Non-Blocking ScreenWatcher Loop | Refactor `ScreenWatcher.tick()` and sub-ticks to run heavy sensing in background | M1 | Survey R1 |
| 4 | Event-Driven Capture Offloading | Offload `Copilot.captureScreen` on `.focusChanged` off `@MainActor` | M1 | Survey R1 |
| 5 | AppKit First Responder Correction | Reorder `makeKeyAndOrderFront` and `makeFirstResponder(contentView)`, configure `becomesKeyOnlyIfNeeded = false` | M2 | Survey R2 |
| 6 | Multi-Round Focus Suppression Reset | Reset `chatInputFocusSuppressed = false` on approval resolve/window close to prevent dead zones | M2 | Survey R2 |
| 7 | Objective Field Focus Shielding | Disable/shield `screenObjectiveText` when awaiting approval | M2 | Survey R2 |
| 8 | Asynchronous Focus Restoration | Replace synchronous `RunLoop.current.run` in `ToolApprovalUI.restoreFocus` with async non-blocking task | M2 | Survey R2 |
| 9 | Tool Approval Window Dismissal | Ensure `Copilot.toolApprover()` dismisses/closes floating panel on approval | M2 | Survey R2 |
| 10 | Non-Blocking Screen Observation Tests | Automated tests verifying `ScreenWatcher` ticks do not trip `MainThreadWatchdog` | M3 | Survey R3 |
| 11 | Multi-Round Approval Unit Tests | Automated tests in `ChatWindowDismissalTests` verifying 3+ consecutive approval cycles | M3 | Survey R3 |
| 12 | Quality Gate & Regression Verification | Verify `Scripts/gate.sh --stage 1`, `MCASensingTests`, `MCAPresentationTests`, `mcaTests` | M3 | Survey R3 |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | M1: Non-Blocking Screen Observation | Refactor `AccessibilityReader`, `FrameFingerprint`, and `ScreenWatcher` sensing pipeline off `@MainActor` (Features 1-4) | none | DONE |
| 2 | M2: Responsive Action Approval Presentation | Refactor `ChatWindow`, `ChatView`, `HUDState`, `ToolApprovalUI`, and `Copilot` approval presentation (Features 5-9) | none | DONE |
| 3 | M3: Verification, Test Coverage & Quality Gate | Add regression tests for non-blocking observation and multi-round approvals; pass all quality gates (Features 10-12) | M1, M2 | DONE |

## Interface Contracts

### `MCASensing.AccessibilityReader`
- `public func readFocusedWindowAsync() async -> Snapshot?`
- `public func readWindowAsync(pid: pid_t) async -> Snapshot?`
- Timeout: `AXUIElementSetMessagingTimeout(axApp, 0.5)` applied to foreign applications.
- Traversal: Maximum execution time budget per window inspection.

### `MCASensing.FrameFingerprint`
- `public static func computeAsync(_ image: CGImage, gridSize: Int, levels: Int, masking: [CGRect]) async -> String?`
- Runs CoreGraphics downscaling and masking inside background cooperative thread pool.

### `MCAPresentation.ChatWindow` ↔ `mca.ToolApprovalUI` / `mca.Copilot`
- `public func presentForApproval()`:
  - Sets `state.chatInputFocusSuppressed = true`
  - Calls `window.makeKeyAndOrderFront(nil)`
  - Calls `window.makeFirstResponder(window.contentView)`
  - Configures `window.becomesKeyOnlyIfNeeded = false` and `window.initialFirstResponder = window.contentView`
- `public func close()`:
  - Resets `state.chatInputFocusSuppressed = false`
- `restoreFocus(to app: NSRunningApplication?) async`:
  - Replaces nested runloop with non-blocking async activation check using `Task.sleep`.

## Code Layout
- `Sources/MCASensing/AccessibilityReader.swift`
- `Sources/MCASensing/FrameFingerprint.swift`
- `Sources/mca/ScreenWatcher.swift`
- `Sources/mca/ToolApprovalUI.swift`
- `Sources/mca/Copilot.swift`
- `Sources/MCAPresentation/ChatWindow.swift`
- `Sources/MCAPresentation/ChatView.swift`
- `Sources/MCAPresentation/HUDState.swift`
- `Tests/MCASensingTests/`
- `Tests/MCAPresentationTests/ChatWindowDismissalTests.swift`
- `Tests/mcaTests/`

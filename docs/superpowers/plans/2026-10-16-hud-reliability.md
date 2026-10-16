# HUD Reliability Implementation Plan

> **For agentic workers:** Use the task ownership below for parallel work, then review the integrated diff and run cloud regression/build checks. Keep the existing feature branch; leave the user's untracked handoff documents intact.

**Goal:** Restore reliable HUD interaction, collapse/expand, exit/restart and responsive rendering.

**Architecture:** Keep the current two hosted native windows. Separate input ownership, process/session ownership and bounded drawable acquisition; keep UIKit/ImGui state on the main queue.

**Tech Stack:** Objective-C++, UIKit, IOHID/BKS, Dear ImGui, Metal, Darwin notify, GitHub Actions macOS.

**Spec:** `docs/superpowers/specs/2026-10-16-hud-reliability-design.md`

## Global Constraints

- iPadOS 16.6.1 / iPad8,11 / TrollStore; Windows host lacks Xcode.
- Do not modify KFD, game offsets, entitlement grants, or the working native context registration sequence.
- Do not uninstall, erase, reboot or terminate unrelated processes.
- No success claim for real touch/performance without fresh device evidence.

## Task 1: Reproduce input and menu regressions (root)

Files: `tests/hud_input_bridge_regressions.mm`, `tests/hud_uikit_regressions.mm`, new menu integration suite, `tests/run_hud_uikit_regressions.py`, regression workflow.

- [x] Preserve and run the existing other-finger move/up regression.
- [x] Add nearby second Began, raw-ID/internal-token collision, blank-space Began then move into control, ball tap/drag/cancel and menu context creation cases.
- [x] Exercise production menu and overlay with CPU ImGui frames for fixed header, clipped hit rectangles and scroll/popup reachability.
- [x] Run each simulator suite as an independent CI job so one failure cannot hide another.
- [x] Save failure logs against the unchanged production baseline.

## Task 2: Session-scoped stop/restart (lifecycle implementer)

Files: `MFHUDControl.*`, `MFHUDLauncher.*`, `MFHUDApplication.mm`, `MFHUDStartupStatus.mm`, lifecycle tests. Root integrates delegate/UI changes.

- [x] Add child-process tests for cooperative exit, blocked main queue, retained PID after failed stop and session isolation; run them against baseline.
- [x] Separate exit request from PID record; retain and validate executable/session ownership.
- [x] Install background control before UIKit bootstrap, arm exit deadline before main cleanup, and reuse stop logic for startup failure.
- [x] Serialize start/stop, reap children and retain terminal startup status.
- [x] Run lifecycle regressions and report exact limits.

## Task 3: Bound renderer waiting (render implementer)

Files: `MFOverlayView.*`, `MFImGuiContext.*`; root integrates `MFDrawingLayer.mm` and menu behavior.

- [x] Add a renderer integration test whose drawable acquisition blocks; main queue must remain responsive and stop/restart must reject stale work.
- [x] Move only drawable acquisition off main, permit at most one pending acquisition per overlay, bound GPU frames and clear lifecycle generations on stop.
- [x] Maintain actual ImGui DeltaTime and adaptive frame rate; avoid stale frames after a resize.
- [x] Expose `acceptsInteractionAtPoint:` as the shared input geometry, clip/reject malformed rectangles, and keep existing public capture APIs compatible.
- [x] Run the real overlay regression and review context thread ownership.

## Task 4: Repair interaction/layout (root)

Files: `MFHUDInputBridge.mm`, `MFHUDWindow.mm`, `MFMenuUI.*`, `MFHUDAppDelegate.mm`, `RootViewController.mm`.

- [x] Verify HID field layout with known factory values; validate field layout, remove proximity token rewriting; hardware feedback later corrected ownership to full digitizer index (see the follow-up below).
- [x] Share input hit geometry and distinguish ball tap from drag with an 8-point movement threshold.
- [x] Make menu role stable at native context creation.
- [x] Fix header/tabs/footer with a scrolling child, clip hit regions and expose popups/scrollbars.
- [x] Resize the native menu window to 56×56 on collapse and restore its size on expansion, retaining location and orientation.
- [x] Remove the unsafe dual-response passthrough switch and per-frame color saves.
- [x] Prevent delayed startup/frame callbacks from reviving a stopped HUD; update console status on foreground/periodic observation.

## Task 5: Integrated verification and delivery (root + independent reviewer)

- [x] Run font generation, source preflight, Python tests, diff whitespace checks and all cloud native/IOHID/UIKit/menu/render regressions.
- [x] Resolve independent review findings and re-run only affected tests plus final integration checks.
- [x] Build and verify an IPA for the reviewed SHA; save hash, build logs and an accurate install/acceptance report.
- [ ] Inspect fresh USB device state when available and perform authorized targeted runtime checks.
- [x] Write a current functional-gap audit based on source consumers, separating historical claims and unverified gameplay.

## Execution rulings / progress

- The user has already authorized fixes and redesign; no extra design approval round is required.
- Existing feature branch is the working isolation boundary. No main-branch edits or force pushes.
- Parallel implementers own disjoint files; root alone edits the app delegate, menu and shared workflow.
- Cloud jobs and compile results do not replace device acceptance.
- Candidate app SHA is `3859ba12739c75e6360cdece616ba9ea8303b96c` (M5.69). Native/windows/input/game-reader/overlay passed in run `38809198137`; the menu job failed in the simulator screenshot utility with an empty PNG, so the complete run is not green.
- Overlay diagnostic run `38809725731` passed without relaxing deadlines; an earlier intermittent first-frame failure remains recorded, not silently declared resolved.
- Test-only commit `53a254b` replaces the menu preview's fixed lifetime with a screenshot acknowledgement, preserves fixture output on utility failures, and rejects incomplete PNGs. Run `38810544740` still timed out in screenshot; its saved report confirms CPU checks and GPU READY, but no suite PASS. Test-only `7d162c6` isolates any remaining launch CLI before capture; run `38811206407` passed with a complete PNG and a new fixture PASS. The CLI had already exited (status 0), so launch-lock causation is unproven. The actual screenshot took about 25.4 seconds, exceeding the old fixed eight-second preview lifetime.
- All six production suites now have passing records for identical app code: five in `38809198137`, menu in `38811206407` with test-only lifecycle changes. The original run retains its failure status. The actual Metal screenshot was visually checked; Chinese labels and fixed controls are intact.
- Independent final review found no remaining production blocker, confirmed the P2 fix and rejected false-green paths in screenshot acknowledgement; physical device acceptance remains separate.
- M5.69 is now installed and independently confirmed through USB (3859ba1-r69). Fresh device feedback shows the three tabs/collapse still fail: raw identity changes 3 -> 2 on lift, while full index stays stable. The previous fixture checked AX changes only and missed this hardware case. The follow-up production candidate is d7b16ad; physical acceptance of that candidate remains pending.

## Follow-up: M5.69 hardware contact ownership

- [x] Capture M5.69 logs and confirm installed build through USB.
- [x] Confirm the user means the three production page tabs.
- [x] Observe true RED with real IOKit events against unchanged production (run 38835131771, job 116762445532).
- [x] Switch ownership/validity from raw identity to full uint32 digitizer index; preserve all cancellation and foreign-finger protections.
- [x] Add real page-button clicks and three collapse/56pt-ball/expand cycles with UIKit bounds.
- [x] Run local preflight, structure, entitlement, Python and whitespace checks.
- [x] Read updated full regression and Release build results; resolve review findings. Six suites have fresh PASS records for d7b16ad; retain attempt1 input/windows launch failures.
- [x] Verify/package the exact built IPA and provide a version-specific install URL. M5.70/d7b16ad-r70; HTTP8187 hash verified.
- [ ] Confirm new installed version and physically verify tabs, ball tap/drag, passthrough, exit and restart.

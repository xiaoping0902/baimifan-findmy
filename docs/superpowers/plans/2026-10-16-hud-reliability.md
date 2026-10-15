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

- [ ] Preserve and run the existing other-finger move/up regression.
- [ ] Add nearby second Began, raw-ID/internal-token collision, blank-space Began then move into control, ball tap/drag/cancel and menu context creation cases.
- [ ] Exercise production menu and overlay with CPU ImGui frames for fixed header, clipped hit rectangles and scroll/popup reachability.
- [ ] Run each simulator suite as an independent CI job so one failure cannot hide another.
- [ ] Save failure logs against the unchanged production baseline.

## Task 2: Session-scoped stop/restart (lifecycle implementer)

Files: `MFHUDControl.*`, `MFHUDLauncher.*`, `MFHUDApplication.mm`, `MFHUDStartupStatus.mm`, lifecycle tests. Root integrates delegate/UI changes.

- [ ] Add child-process tests for cooperative exit, blocked main queue, retained PID after failed stop and session isolation; run them against baseline.
- [ ] Separate exit request from PID record; retain and validate executable/session ownership.
- [ ] Install background control before UIKit bootstrap, arm exit deadline before main cleanup, and reuse stop logic for startup failure.
- [ ] Serialize start/stop, reap children and retain terminal startup status.
- [ ] Run lifecycle regressions and report exact limits.

## Task 3: Bound renderer waiting (render implementer)

Files: `MFOverlayView.*`, `MFImGuiContext.*`; root integrates `MFDrawingLayer.mm` and menu behavior.

- [ ] Add a renderer integration test whose drawable acquisition blocks; main queue must remain responsive and stop/restart must reject stale work.
- [ ] Move only drawable acquisition off main, permit at most one pending acquisition per overlay, bound GPU frames and clear lifecycle generations on stop.
- [ ] Maintain actual ImGui DeltaTime and adaptive frame rate; avoid stale frames after a resize.
- [ ] Expose `acceptsInteractionAtPoint:` as the shared input geometry, clip/reject malformed rectangles, and keep existing public capture APIs compatible.
- [ ] Run the real overlay regression and review context thread ownership.

## Task 4: Repair interaction/layout (root)

Files: `MFHUDInputBridge.mm`, `MFHUDWindow.mm`, `MFMenuUI.*`, `MFHUDAppDelegate.mm`, `RootViewController.mm`.

- [ ] Verify HID field layout with known factory values; use full identity ownership and remove proximity token rewriting.
- [ ] Share input hit geometry and distinguish ball tap from drag with an 8-point movement threshold.
- [ ] Make menu role stable at native context creation.
- [ ] Fix header/tabs/footer with a scrolling child, clip hit regions and expose popups/scrollbars.
- [ ] Resize the native menu window to 56×56 on collapse and restore its size on expansion, retaining location and orientation.
- [ ] Remove the unsafe dual-response passthrough switch and per-frame color saves.
- [ ] Prevent delayed startup/frame callbacks from reviving a stopped HUD; update console status on foreground/periodic observation.

## Task 5: Integrated verification and delivery (root + independent reviewer)

- [ ] Run font generation, source preflight, Python tests, diff whitespace checks and all cloud native/IOHID/UIKit/menu/render regressions.
- [ ] Resolve independent review findings and re-run only affected tests plus final integration checks.
- [ ] Build and verify an IPA for the reviewed SHA; save hash, build logs and an accurate install/acceptance report.
- [ ] Inspect fresh USB device state when available and perform authorized targeted runtime checks.
- [ ] Write a current functional-gap audit based on source consumers, separating historical claims and unverified gameplay.

## Execution rulings / progress

- The user has already authorized fixes and redesign; no extra design approval round is required.
- Existing feature branch is the working isolation boundary. No main-branch edits or force pushes.
- Parallel implementers own disjoint files; root alone edits the app delegate, menu and shared workflow.
- Cloud jobs and compile results do not replace device acceptance.

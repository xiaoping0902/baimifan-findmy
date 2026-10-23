# Drawing source recovery implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement and review these tasks. Tests must exercise production behavior with synthetic data.

**Goal:** Allow the existing external feed to render without a local task port, and report the actual limits of device validation.

**Architecture:** Keep source selection in `MFDrawingLayer.acquireFrameWithSize`. The render entry must not preempt that selection with a local-only readiness check. Use the actual UDP decoder and ImGui draw data to verify the fix, without reading game memory.

**Tech Stack:** Objective-C++, UIKit, Metal, Dear ImGui, Python, GitHub Actions macOS.

**Spec:** User request to diagnose invisible drawing, fix verified defects, build an IPA, and test on the connected iPad. Device identity observed: iPad14,4 / J618AP, 2022 iPad Pro 11-inch M2 Cellular, iPadOS 16.1 (20B82). Historical mini 6/A15 descriptions are incorrect.

**Delivery scope update:** The user chose “现在不方便，先完成渲染修复与打包”. Finish the rendering fix and package in this delivery; defer installation of the new IPA, physical visibility confirmation, and live game validation. Existing M5.90 synthetic runtime observations are recorded separately from the new package's simulator regression.

## Constraints

- Preserve the existing kernel diagnostic mode; do not enable speculative kernel writes.
- Do not treat a successful build, GPU completion, or synthetic frame as verified live game drawing.
- Keep raw device logs and identifiers local under `diagnostics/`.

## Task 1: Reproduce and fix source selection

Files: `tests/hud_drawing_regressions.mm`, `tests/run_hud_uikit_regressions.py`, `.github/workflows/hud-regressions.yml`, `app/Sources/HUD/MFDrawingLayer.mm`.

- [x] Add a simulator suite which runs the real drawing delegate with null local port and zero module base. Assert the real UDP receiver starts, send a literal synthetic camera/entity packet, and assert a visible entity generates ImGui vertices.
- [x] Run the suite against the unchanged production entry and confirm the receiver startup assertion fails. CI run 40005661549, drawing job 120592789146, commit 86ede17: expected receiver startup assertion failed.
- [x] Remove the local-only early return preceding `acquireFrameWithSize`; retain the existing source selection and failures within each source.
- [x] Run the drawing suite again and confirm it passes. CI run 40006474956, job 120595561324: real synthetic UDP decoded, one entity, 10 vertices and 24 indices, with no local task port or remote memory reads.
- [x] Run static and entitlement checks: 168 preflight checks passed (9 existing SPI reminders); 3 entitlement tests passed; diff whitespace check passed.
- [x] Record the existing regression matrix's final result: native, input, windows, menu, overlay and drawing passed on attempt 1; game-reader had no result file on attempt 1 and passed the single-job rerun 120601076029 without code changes. Preserve both logs and do not claim a clean first attempt.
- [x] Obtain independent review of the final diff. No blocking findings; local guards and kernel diagnostic mode preserved.

## Task 2: Build and device evidence

Files: local `diagnostics/2026-10-24/`, `dist/` package, `docs/绘制排查与验证-2026-10-24.md`.

- [x] Confirm installed version, USB identity, current HUD session, and read existing logs before invoking any app actions.
- [x] Build the reviewed commit with the existing macOS workflow, download the exact artifact, verify its embedded commit/version and entitlements, and calculate SHA-256. Delivered M5.91 / b05aec3-r91, build 40006476076.
- [x] Document what passed, what failed, and remaining data source or physical visibility limitations in the Chinese verification report and versioned release notes, without claiming new-package installation or live game success.

## Deferred validation

- New-package installation through the existing TrollStore path and confirmation of the running M5.91 identity. No callable existing install helper was found during this round; the IPA has not been installed.
- Physical visibility on the iPad and live game data validation. These are outside the user's revised delivery scope and remain unverified.

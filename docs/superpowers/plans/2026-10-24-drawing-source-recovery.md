# Drawing source recovery implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement and review these tasks. Tests must exercise production behavior with synthetic data.

**Goal:** Allow the existing external feed to render without a local task port, and report the actual limits of device validation.

**Architecture:** Keep source selection in `MFDrawingLayer.acquireFrameWithSize`. The render entry must not preempt that selection with a local-only readiness check. Use the actual UDP decoder and ImGui draw data to verify the fix, without reading game memory.

**Tech Stack:** Objective-C++, UIKit, Metal, Dear ImGui, Python, GitHub Actions macOS.

**Spec:** User request to diagnose invisible drawing, fix verified defects, build an IPA, and test on the connected iPad. Device identity observed: iPad14,4 / J618AP, 2022 iPad Pro 11-inch M2 Cellular, iPadOS 16.1 (20B82). Historical mini 6/A15 descriptions are incorrect.

## Constraints

- Preserve the existing kernel diagnostic mode; do not enable speculative kernel writes.
- Do not treat a successful build, GPU completion, or synthetic frame as verified live game drawing.
- Keep raw device logs and identifiers local under `diagnostics/`.

## Task 1: Reproduce and fix source selection

Files: `tests/hud_drawing_regressions.mm`, `tests/run_hud_uikit_regressions.py`, `.github/workflows/hud-regressions.yml`, `app/Sources/HUD/MFDrawingLayer.mm`.

- [x] Add a simulator suite which runs the real drawing delegate with null local port and zero module base. Assert the real UDP receiver starts, send a literal synthetic camera/entity packet, and assert a visible entity generates ImGui vertices.
- [x] Run the suite against the unchanged production entry and confirm the receiver startup assertion fails. CI run 40005661549, drawing job 120592789146, commit 86ede17: expected receiver startup assertion failed.
- [x] Remove the local-only early return preceding `acquireFrameWithSize`; retain the existing source selection and failures within each source.
- [ ] Run the suite again and confirm it passes, alongside existing regressions and static/entitlement checks.
- [ ] Obtain independent review of the final diff.

## Task 2: Build and device evidence

Files: local `diagnostics/2026-10-24/`, `dist/` package, `docs/绘制排查与验证-2026-10-24.md`.

- [ ] Confirm installed version, USB identity, current HUD session, and read existing logs before invoking any app actions.
- [ ] Build the reviewed commit with the existing macOS workflow, download the exact artifact, verify its embedded commit/version and entitlements, and calculate SHA-256.
- [ ] Install through the project's existing TrollStore path when available; validate the running package identity and nonempty synthetic drawing separately from live game data.
- [ ] Document what passed, what failed, and remaining data source or physical visibility limitations without claiming unobserved success.

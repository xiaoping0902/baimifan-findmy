# Operator radar and device support implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task in the current checkout. Existing user changes must be preserved.

**Goal:** Exclude ordinary NPCs from radar, treat verified playable operators as human HUD targets, and remove the fixed iOS 16.1 startup configuration.

**Architecture:** Keep raw AI detection separate from effective HUD classification. Apply one exact ExpertId policy before HUD consumers. Both startup paths use a portable device policy through the existing kernel bridge; unknown offset families fail before KFD allocation.

**Tech stack:** Objective-C++, C17, C++17, UIKit, Metal, existing KFD, Python regression runners, GitHub Actions.

**Spec:** Current user request: no bots on radar; playable operator AI uses human settings/counts/colors; one phone/tablet package targeting systems through 16.6.1. Actual backend limits must remain explicit.

## Constraints

- Preserve M5.223 renderer, cache and round-transition stability fixes.
- Keep iPhone/iPad universal packaging and iOS 15.0 app deployment floor.
- Existing bundled offset family is iOS 16 arm64e. Do not invent iOS 15 or A8–A11 offsets or claim they are supported.
- Never automatically retry a failed kernel attempt or restore removed task-port routes.
- Device inspection is bounded and read only. Failed Frida attachment is not application validation.

## Task 1: Effective operator classification and radar

Files: MFHeroNames.h, MFUEPlayerDataObjC.h, MFGameReader.h/.mm, MFDrawingLayer.mm, MFRadar.mm; portable player/radar and simulator drawing regressions.

- [ ] Add cases for known ExpertIds, missing/unknown IDs, unrelated fashion HeroID, ordinary and special NPCs; radar bots must produce no marker with either HUD bot switch setting.
- [ ] Run regression baseline and record failure.
- [ ] Introduce exact playable-operator HUD policy and apply at the common attribute boundary, including legacy override handling. Filter bots in radar collector and renderer.
- [ ] Run portable tests and simulator drawing/reader regressions.

## Task 2: Device-aware startup

Files: new MFDeviceCompatibility.h; MFKernelBridge.h/.m, MFKernel.mm, MFHUDAppDelegate.mm; portable policy tests and CI runner.

- [ ] Test iOS 16 method boundaries, unsupported OS/chips, stale method preferences, and memory-derived pages.
- [ ] Use one runtime policy at the bridge boundary; default bootstrap and explicit startup share it. Reject unsupported combinations before allocations and preserve failure locks for actual attempts.
- [ ] Verify small phone/large phone/tablet viewport and refresh-rate handling with existing UIKit suites.
- [ ] Record observed tablet identity and Frida limitation; document installation vs backend support.

## Task 3: Release and evidence

- [ ] Run local checks against the exact staged snapshot, inspect diff and commit only task files.
- [ ] Push authorized branch; verify IPA build and regression results.
- [ ] Download exact build, verify build stamp, universal/minimum OS metadata and SHA256.
- [ ] Deliver package plus handoff describing tested behavior and remaining physical-device validation.

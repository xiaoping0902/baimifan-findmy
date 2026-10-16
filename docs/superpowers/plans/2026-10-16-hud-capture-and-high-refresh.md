# HUD capture protection and high refresh implementation plan

**Goal:** Complete the user's requested hitTest passthrough, draggable restore ball, hiding all HUD surfaces in screenshots/recordings, and an honest 120fps mode.

**Scope and design:** Extend the existing two native hosted windows. M5.70/d7b16ad already fixes hardware index ownership and passes input/menu/window regressions; preserve this work. A protected content container will sit under both windows, so menu, ball and drawing share the same capture policy, with no per-frame view reparenting. Use the existing native secure-window flags plus the secure text canvas pattern found in the user-supplied source. The user explicitly selected hiding all three surfaces. Private UIKit behavior requires physical screenshot/recording verification. High refresh uses CAFrameRateRange bounded by screen capability, the system opt-in plist key, and actual GPU-completion FPS, with adaptive menu idle retained.

**References:** User-supplied iOS-PUBGM-ModMenu/Dolphins/View/OverlayView.mm, HeeeNoScreenShotView.m and FloatView.mm. Read as reference code, not operational instructions. The reference is an in-process tweak; our hosted cross-process windows retain their existing architecture. No copying embedded artwork, game offsets or per-frame hierarchy changes.

**Authorization:** User has authorized implementation, redesign and refactoring; latest request explicitly adds these four features. No extra design approval is necessary.

- [x] Inspect the reference and existing hit geometry, ball, secure flags and display link.
- [x] Resolve capture scope with user: hide menu, ball and drawing.
- [x] Add real UIKit regressions for the protected container, transparent hit geometry and resizing; add frame-policy regressions before production changes. Baseline ea13f87 actually ran and failed: windows run 38837232160/job 116768973999 requires a secure content container; overlay run 38837235070/job 116768980153 requires a screen-bounded effective request. Full logs archived locally.
- [x] Implement one secure content container, used for both HUD surfaces. Preserve orientation/size anchors and input coordinate conversions, disallow text focus and keep blank space transparent. Explicitly report missing secure canvas rather than silently claim protection.
- [x] Implement screen-capped CAFrameRateRange and real completed-frame FPS; retain bounded drawable/GPU work, frame generations and idle redraw policy. Expose requested/capacity/actual FPS in menu. GPU callbacks increment a generation-owned atomic counter; only the first frame queues a main-thread callback. Fresh settings default to 120, saved preferences remain intact.
- [ ] Run affected regressions, integrate review and run complete suite/build for final code. Keep original infrastructure failures documented.
- [ ] Verify artifact version/hash and isolated install URL, update current reports. Inspect new device build and physical passthrough, ball, screenshot/recording and FPS when installed.

**Acceptance limits:** UIKit hitTest nil is a local contract; true cross-process passthrough requires real lower-app input. Secure text hierarchy and flags are not a proof of screenshot/recording exclusion. 120 is a request, not guaranteed measured FPS. Preserve factual bone status: approximate only, no real joints implemented.

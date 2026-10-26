# HUD labels, quality and controls implementation plan

**Goal:** Show weapon, slot durability, team and nickname, hero and health above each character; fix dropped item quality, color editor stability and directional radar/offscreen markers.

**Architecture:** Keep the existing UIKit/Metal/ImGui UI and category cadence. Read player identity, item quality and durability through validated SDK fields; preserve unknown data. Separate text formatting from acquisition so current durability can display without a maximum value. Keep radar team colors independent of human/bot skeleton preferences.

**User specification:** Latest message requests weapon name without a prefix; `4头35 5甲105 6包`; `队伍号 : 玩家昵称`; hero name plus health bar; distance below feet; six-level dropped loot colors; stable color controls; enemy heading and stable team colors on radar; a separate nonoverlapping offscreen arrow per enemy; white bots and red humans.

- [x] SDK data: reproduce durability and dropped-quality failures using synthetic records, validate SDK offsets and fallback rules, add distinct hero identity and preserve name/weapon values.
- [x] Entity labels: portable formatter regression for current-only and zero durability, empty/unknown gear and nickname rows; integrate exact row layout, remove numeric UIN from visible label and preserve tracer endpoint.
- [x] UI colors: reproduce popup flicker with real ImGui frames, keep popup placement/identity stable while editing; migrate only the exact previously shipped bot default to white and keep custom colors.
- [x] Radar/offscreen: trace heading acquisition to rendering, test verified fallbacks; assign stable team colors and replace grouped markers with individual arrows arranged to avoid overlap.
- [x] Integration: update Apple fixtures for actual rendering and settings persistence; run relevant portable tests and preflight; inspect diff and independent review.
- [ ] Delivery: push authorized branch, verify macOS UIKit suites and ARM64 IPA build, inspect current menu screenshot, download and verify exact commit/version/asset digest.

Validation uses the repository's portable C++ regression runners, `tests/run_hud_uikit_regressions.py` on GitHub macOS, `scripts/preflight.py` and `scripts/verify_ipa.py`. Do not infer item quality from value, fabricate hero/weapon names or render an unknown heading as a verified direction. Preserve unrelated dirty files and stage only this task's files.

Latest additions: use all 16 exact ID/name pairs in the supplied `干员名字表.md` only as a fallback to live HeroData names; retain current SDK offsets. Add a default-on, independent top-left FPS badge and Home switch. Measure actual overlay presentation timestamps with CAMetalDrawable presented handlers, preserve GPU completion FPS separately, show `FPS --` without valid recent samples, and clear measurements across rendering generations.

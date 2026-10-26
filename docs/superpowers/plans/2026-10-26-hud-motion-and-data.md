# HUD motion, data and presentation

User-authorized changes: smaller two-number island; real-player red and bot green skeleton/tracer with independent color controls; real-player/bot/loot geometry budgets of 120/60/30 Hz; actual player names; explicit empty gear; compact directional radar and behind-camera markers; movable statistics; crisp panel and heavier labels; downed skeletons; teammates always excluded.

Keep UIKit/Metal/ImGui, existing top-center island, input routing and resize. Cap display presentation at actual screen capability. A composed frame must retain cached lower-frequency geometry rather than omit it between updates. Rebuild cached geometry immediately after visibility/settings/viewport changes or font-atlas replacement.

- [x] Validate SDK name, UIN, armor array stride and alive/downed fields; fix shared readers with synthetic memory tests.
- [x] Append independent bot skeleton color, persist both controls, shrink island, make statistics position configurable and remove teammate switch.
- [x] Simplify self/target radar markers; show only verified fresh facing, aggregate behind-camera indicators.
- [x] Add category geometry cadence, update bone poses at 120/60 Hz, preserve prone/downed skeleton validation, stronger text and explicit empty gear.
- [ ] Run portable tests/preflight; independent review; push existing authorized branch; verify GitHub UIKit suites, real screenshot and release IPA.

SDK contains schemas/classes, not a verified complete localized item-ID table. Add loot mappings only with evidence; retain unknowns when rows are unavailable.

Dictionary supplied later by the user: `C:/Users/xiaoping/Desktop/Zcode/rea_ipa_work/内置字典ID对应表.md`. All 891 ID/name entries already match MFItemNames exactly (zero missing, conflicts or duplicates). Quality palette: white/green/blue/purple/gold/red; gear slots receive separate colors.

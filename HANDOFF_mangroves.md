# HANDOFF — Mangrove bathymetry modification (`mangroves` branch)

**Branch:** `mangroves` (created from `main`)
**Repo:** Celeris-WebGPU (`plynett.github.io`)
**Created:** 2026-08-20
**Owner:** David / Patrick Lynett

---

## How to use this file

This is the working plan for a multi-session task. **After finishing each phase, update that
phase's `Status:` line and fill in its `Notes:` block, then update the summary table below.**
Do not delete completed phases — the notes are the record of what was actually done and why.

Status values: `NOT STARTED` · `IN PROGRESS` · `DONE` · `BLOCKED` · `SKIPPED`

| # | Phase | Status |
|---|-------|--------|
| 0 | Branch + baseline verification | DONE |
| 1 | Constants and UI wiring | DONE |
| 2 | Uniform buffer plumbing | DONE |
| 3 | Shader branch — bathy from component footprint | DONE |
| 4 | JS dispatch + texture copy block | NOT STARTED |
| 5 | Original-bed stash (idempotence + undo) | NOT STARTED |
| 6 | Footprint and edge-taper reconciliation | NOT STARTED |
| 7 | Integration checks (sed transport, sea level, export, 3D, agent API) | NOT STARTED |
| 8 | Manual test matrix + docs | NOT STARTED |

---

## Goal

When the user paints a **mangrove** area (design component ID 3) in the design panel, the
bathymetry/topography inside the painted footprint is set to a user-specified elevation, in
addition to the existing behavior (component ID written to `txDesignComponents`, friction
written to `txBottomFriction`).

### Decisions already locked in

| Decision | Choice |
|---|---|
| Implementation approach | **A — second dispatch** of `MouseClickChange.wgsl` behind a new mode flag. No new textures, no bind-group layout changes. |
| Elevation semantics | **Set exactly** — `B = target` inside the footprint (may excavate bed that is currently higher than the target). |
| Scope | **Mangrove only** for this branch. Design the constants so extending to the other nine components later is mechanical. |

Rejected alternatives, for the record: (B) third storage texture — more plumbing in
`Handler_MouseClickChange.js` for one fewer dispatch; (C) degenerate the linear-structure
capsule to a disc — fights the click-two-endpoints UI flow and only supports `max()`;
(D) canopy layer in Pass1/Pass2 — physically the better long-term answer for emergent
vegetation, but a much larger change to the model itself. Keep (D) in mind as the eventual
direction if the goal shifts from mangrove *geometry* to mangrove *physics*.

---

## Orientation — how the code works today

Serve with `python -m http.server 8000`; no build step, no test suite, no bundler. Chrome 113+.

**Paint path.** With the design panel open (`whichPanelisOpen == 2`), clicking or dragging on
the canvas sets `calc_constants.click_update = 1`, and the block at **`js/main.js` ~2502–2571**
uploads uniforms and runs one dispatch of `shaders/MouseClickChange.wgsl`. That shader writes
exactly **two** storage textures:

- binding 6 → `txtemp_MouseClick` → copied to `txDesignComponents` — component ID in `.x`,
  painted as a **hard disc**, `r <= 0.5 * designcomponent_Radius`
- binding 7 → `txtemp_MouseClick2` → copied to `txBottomFriction` — friction blended with a
  **Gaussian**, `k = 4 / designcomponent_Radius`

`txBottom` is bound read-only at binding 1 and `txstateUVstar` at binding 4 (the shader calls
that one `txState` — it is *not* `txState`/`txNewState`). Nothing in the design branch writes
bathymetry today.

**Bathy edit path (the pattern to copy).** Both `surfaceToChange == 1` and the linear-structure
branch do the same four-step follow-up in JS after the dispatch (`js/main.js` ~2531–2541 and
~2556–2567):

```js
runCopyTextures(device, calc_constants, txtemp_MouseClick,  txBottom)
runCopyTextures(device, calc_constants, txtemp_MouseClick2, txstateUVstar)
runComputeShader(device, Updateneardry_...)          // recompute near-dry flag B.w
runCopyTextures(device, calc_constants, txtemp_bottom, txBottom)
if (calc_constants.NLSW_or_Bous >= 1) runComputeShader(device, UpdateTrid_...)
```

**Texture layouts.**

- `txBottom`: `.z` = bed at cell center, `.x` = bed at north face `(i, j+1/2)`, `.y` = bed at
  east face `(i+1/2, j)`, `.w` = near-dry flag (recomputed by `shaders/Update_neardry.wgsl`).
  Clamp floor in the shader is `min_val = -globals.base_depth`.
- `txstateUVstar`: `.x` = eta, `.y` = P, `.z` = Q.
- `txDesignComponents`: only `.r/.x` is used anywhere (written in `MouseClickChange.wgsl`, read
  in `shaders/fragment.wgsl:397` and `:379`). **`.y/.z/.w` are free**, and the shader already
  preserves them because it loads the full `vec4`, edits `.x`, and stores the whole thing.
  Phase 5 exploits this.

**Key files and line anchors** (line numbers are from `main` at branch time — re-grep, do not
trust them blindly after edits):

| File | What |
|---|---|
| `shaders/MouseClickChange.wgsl` | `Globals` struct; `whichPanelisOpen == 2` design branch; `calc_linear_structure_elevation` is the model for the new elevation function |
| `js/main.js` ~2502–2571 | click-update block: uniform writes, dispatch, copy targets |
| `js/main.js` 2514–2523 | `designcomponentToAdd` → `designcomponent_Friction` if-chain (mangrove is `== 3`) |
| `js/main.js` 1350 | `MouseClickChange_uniforms = new ArrayBuffer(256)` |
| `js/main.js` 1364–1379 | initial uniform writes + `updateMouseClickLinearStructureUniforms()` definition |
| `js/main.js` 1349 | `create_MouseClickChange_BindGroup(...)` — note `txstateUVstar` is passed as the `txState` binding |
| `js/main.js` ~4710–4727 | `buttonActions` list — where numeric inputs get wired to `calc_constants` |
| `js/constants_load_calc.js` 327–355 | design-component defaults (`designcomponent_Fric_*` etc.) |
| `index.html` ~530–650 | design panel; mangrove is `<option value="3">`; `designcomponent_CrestElev` block is the input pattern to copy |
| `shaders/fragment.wgsl` 397, 651 | `component_index` decode; mangrove render branch |
| `js/agent_controls.js` | CelerisAgent action surface (`requestAddLinearStructure` etc.) |

**Uniform offsets currently in use** in the 256-byte `MouseClickChange` buffer: `0` width,
`4` height, `8` dx, `12` dy, `16` xClick, `20` yClick, `24` changeRadius, `28` changeAmplitude,
`32` surfaceToChange, `36` changeType, `40` base_depth, `44` whichPanelisOpen,
`48` designcomponentToAdd, `52` designcomponent_Radius, `56` designcomponent_Friction,
`60` changeSeaLevel_delta, `64–88` linear-structure params, `92` designcomponent_AddLinearStructure.
**First free offset is 96.** Plenty of headroom to 256.

---

## Constraints that will bite you

1. **Painting is continuous.** `click_update = 1` fires on every mousemove while the button is
   held (`js/main.js` ~3924), so the bathy operation runs many times over the same cells. It
   **must be idempotent**. Anything of the form `B += dH` grows a mound under the cursor.
2. **Blending against the current bed is not idempotent either.** A taper ring computed as
   `B_new = (1-w)*B_old + w*target` converges toward `target` with repeated strokes, so the
   painted edge creeps. Phase 5 fixes this properly by blending against a *stashed original*
   bed instead of the live one.
3. **Raising the bed above local eta creates negative depth.** The existing bathy path handles
   this with `if (H_here <= 0) { eta = max(0, B); }`. The equivalent here is `eta = max(eta, B)`.
   That path also leaves `P`/`Q` untouched, so a cell that suddenly goes dry keeps its momentum —
   zeroing `.y`/`.z` in newly dried cells is more robust than current precedent.
4. **A hard step at the footprint edge is a numerical shock generator** — expect spurious
   reflections off the mangrove perimeter without a taper (Phase 6).
5. **Footprint mismatch already exists in the code**: the ID disc has radius `0.5*R`, while the
   friction Gaussian `exp(-16 r²/R²)` is down to ~2 % at that same radius. So friction is applied
   over a much narrower area than the painted ID. If bathy follows the ID disc, the outer ring of
   the raised platform will not be rough. Decide and document (Phase 6).
6. **Sea level.** `changeSeaLevel_delta` shifts *bathymetry*, not the datum, so an absolute target
   elevation is automatically "relative to current still-water level", and a platform placed
   earlier correctly becomes relatively lower when sea level later rises. Do not re-derive the
   target from sea level at paint time or you double-count.
7. **Boussinesq coupling.** Any `txBottom` change requires `Updateneardry` and, when
   `NLSW_or_Bous >= 1`, `UpdateTrid`. Skipping these produces slow divergence, not an obvious crash.

### Repo hygiene warning (read before any `git add`)

This checkout lives on an exFAT volume. `git status` shows **~995 files modified** on a clean
tree — every file differs by line endings and by mode `100644 → 100755`. **This is pre-existing,
not your work.** Never run `git add -A` / `git commit -a` on this branch. Stage only the specific
paths you edited:

```bash
git add js/main.js shaders/MouseClickChange.wgsl index.html js/constants_load_calc.js
git status --short -- <those paths>   # verify before committing
```

Follow the existing in-repo comment convention for machine-authored edits (`// CODEX: …` markers
appear throughout the linear-structure work); use a comparable marker so the diff is reviewable.

---

## Phases

### Phase 0 — Branch + baseline verification

**Status:** DONE

Goal: know what "unchanged" looks like before touching anything.

- [x] Create branch `mangroves` off `main`
- [x] `python -m http.server 8001`, open in Chrome, load an example with wet/dry topography
- [x] Open the design panel, select **Mangroves**, paint a patch; confirm current behavior:
      component texture and friction change, bathymetry does **not**
- [x] Note the baseline appearance and console output (clean)
- [x] Confirm the `surfaceToPlot == 22` (design components) view renders the painted patch

**Exit criteria:** baseline reproduced and recorded; no console errors.

**Notes:**
Verified manually in Chrome via `python -m http.server 8001` (8000 was already occupied by
another local process). Painting a mangrove patch: bathymetry unchanged (expected — this is the
gap Phases 1–4 close), component ID texture and friction both changed as expected, no console
errors, `surfaceToPlot == 22` correctly renders the painted patch. Baseline matches the
"Orientation" section's description of current behavior. Clear to proceed to Phase 1.

---

### Phase 1 — Constants and UI wiring

**Status:** DONE

Add the parameters, wire the UI, change no behavior yet.

- [x] `js/constants_load_calc.js` (after line 355, the `designcomponent_Fric_*` block): added
      `designcomponent_Elev_Mangrove` (default `0.5` m) and `designcomponent_SetBathy_Mangrove`
      (`0`/`1`, default `0`, inert)
- [x] `index.html` design panel: new "Mangroves: Set Bathymetry/Topography Elevation" block
      inserted right after the friction inputs, before the `designcomponent_Radius` block —
      numeric input + Update button for elevation (follows the `designcomponent_CrestElev`
      pattern), and a Yes/No select for the enable flag. Both labeled "Mangroves only".
- [x] `js/main.js`: elevation entry added to `buttonActions` (~4728, next to the other
      `designcomponent_*` entries); enable flag added to `button_dropdown_Actions` (~4772, next
      to `designcomponentToAdd-select`) — same generic wiring every other design-component field
      uses, so both auto-round-trip through `updateAllUIElements()`.
- [x] Round-trip confirmed manually in Chrome: input loads at `0.5` / select loads at `No`;
      editing + Update persists the value across other UI interactions; no console errors.

**Exit criteria:** parameters exist and are editable from the UI; simulation behavior is
byte-for-byte unchanged.

**Notes:**
No uniform buffer or shader touched this phase — `designcomponent_SetBathy_Mangrove` exists only
in `calc_constants` and the UI, not yet read anywhere in the click-update path, so behavior is
unchanged by construction, not just by testing. Uniform plumbing is Phase 2.

---

### Phase 2 — Uniform buffer plumbing

**Status:** DONE

- [x] `shaders/MouseClickChange.wgsl`: appended to `Globals`, after
      `designcomponent_AddLinearStructure`:
      `designcomponent_SetBathy: i32` (offset 96),
      `designcomponent_TargetElev: f32` (100),
      `designcomponent_EdgeTaper: f32` (104, unused until Phase 6)
- [x] `js/main.js`: added `updateMouseClickDesignBathyUniforms()` next to
      `updateMouseClickLinearStructureUniforms()` (~1381) writing offsets 96/100/104; called from
      both the init block (~1386) and the click block (~2539)
- [x] In the click block, after the `designcomponentToAdd` if-chain (~2531): set
      `calc_constants.designcomponent_TargetElev` and `designcomponent_SetBathy` from the mangrove
      constants when `designcomponentToAdd == 3`, and to `0` otherwise, via a ternary rather than
      touching each of the 10 existing friction branches — same net effect, smaller diff.
- [x] `js/constants_load_calc.js`: added the "active value" pair `designcomponent_TargetElev` /
      `designcomponent_SetBathy` (mirroring the existing `designcomponent_Friction` active value),
      plus `designcomponent_EdgeTaper` default (`2.0` m) — none of these were in the original
      checklist but were needed so the new uniform writes don't upload `undefined`/`NaN`.
- [x] Verified the 256-byte buffer is still large enough (108 < 256) and the shader compiles.

**Exit criteria:** shader compiles, uniforms upload, flag defaults to 0, behavior unchanged.

**Notes:**
Verified live via the Claude in Chrome extension (`@browser`, connected to a macOS browser with a
working GPU — the first connected browser had no WebGPU adapter at all, unrelated to this work).
Loaded the Ventura Harbor Boussinesq example: console showed `Shaders loaded. Pipelines set up.
Buffers set up. Compute / Render loop starting.` with no errors, confirming the grown `Globals`
struct still matches the JS-side uniform layout. Painted a mangrove patch (design panel →
Mangroves → drag on canvas): `whichPanelisOpen` → 2, `designcomponentToAdd` → 3, five
`Updating Design Components` log lines during the drag, patch rendered visibly on the design
overlay, zero console errors. `designcomponent_SetBathy_Mangrove` was left at its Phase 1 default
(`No`), so the shader took the inert `else` branch exactly as before — confirms Phase 2 changed
nothing observable, as intended. Repo-hygiene note: editing these files with the Edit tool
silently re-normalizes the entire file's line endings against this exFAT checkout's mixed
CRLF/LF blobs, turning a 4-line change into a 2000+ line diff; every Phase 2 edit was instead
applied as a direct byte-level splice against the `git show HEAD:<path>` blob (matching the
existing CRLF/LF convention at each insertion point) so the staged diff stayed minimal. Same
approach should be used for the remaining phases.

---

### Phase 3 — Shader branch: bathy from component footprint

**Status:** DONE

Add a third case inside `whichPanelisOpen == 2`, parallel to the existing
`designcomponent_AddLinearStructure` case.

- [x] Added `fn calc_component_bathy_elevation(xloc: f32, yloc: f32, current_bed: f32) -> f32`.
      One deviation from the checklist's two-argument signature: it takes a third `current_bed`
      parameter and returns *that* outside the footprint (instead of a linear-structure-style
      `-1.0e9` sentinel), because set-exactly semantics can't be expressed as `max(B, target)` —
      the call site needs the untouched value to fall through unchanged, and the function has no
      other way to know it per-channel (`.z`/`.x`/.`y` each need their own fallback).
- [x] Added a `designcomponent_SetBathy == 1` branch to the *load* block (the first
      `whichPanelisOpen == 2` switch, ~line 152): loads `txBottom`/`txState` into
      `B_here`/`B_here2`, `min_val = -base_depth`, exactly mirroring the linear-structure case.
- [x] Added the matching branch to the *compute* block (~line 246): evaluates the footprint at all
      three staggered locations — `.z` at `(xloc, yloc)`, `.x` at `(xloc, yloc + 0.5*dy)`, `.y` at
      `(xloc + 0.5*dx, yloc)`.
- [x] Set semantics implemented as `B_here.<c> = max(min_val, calc_component_bathy_elevation(...))`
      — not `max(B, target)`.
- [x] Free-surface fix: `let newly_dry = B_here.z > B_here2.x;` computed *before* overwriting eta
      (comparing the new center-bed elevation against the pre-edit eta) — the naive
      `B_here2.x <= B_here.z` *after* the max would have been backwards (always false for
      already-wet cells). `B_here2.x = max(B_here2.x, B_here.z)`, then zero `.y`/`.z` momentum
      only when `newly_dry`.
- [x] `textureStore` calls were already unconditional at the end of `main()` — no change needed.

**Exit criteria:** shader compiles; with the flag on, the two temp textures contain the intended
values (verify in Phase 4 once they are copied somewhere visible).

**Notes:**
Same live-browser verification approach as Phase 2 (Claude in Chrome, macOS browser with a working
GPU adapter — reselecting the browser was needed again since the selection didn't persist between
tool calls). Ventura Harbor Boussinesq example: `Shaders loaded. Pipelines set up. Buffers set up.
Compute / Render loop starting.`, zero errors — confirms the new branches and the new function
parse and compile correctly inside the WGSL compiler, even though nothing sets
`designcomponent_SetBathy == 1` yet (that's Phase 4). Re-painted a mangrove patch to confirm the
`else` (component-ID/friction) path is still reached identically to Phase 0/2: five
`Updating Design Components` log lines, patch rendered, zero console errors. Actual numeric
verification of the bathy-set values happens in Phase 4 once there's a second dispatch and a copy
target to inspect. Used the same byte-level blob-splice approach as Phase 2 to keep the diff to
the ~31 real lines added.

---

### Phase 4 — JS dispatch + texture copy block

**Status:** NOT STARTED

This is where the feature becomes visible.

- [ ] In the `whichPanelisOpen == 2` copy block (~2551–2570), after the existing design-component
      copies, add: if `designcomponent_SetBathy` is active for the current component, set the
      uniform flag to 1, run a **second** `runComputeShader(...)` of the same pipeline, then run
      the standard bathy follow-up — `txtemp_MouseClick → txBottom`,
      `txtemp_MouseClick2 → txstateUVstar`, `Updateneardry`, `txtemp_bottom → txBottom`,
      `UpdateTrid` when `NLSW_or_Bous >= 1` — and reset the flag to 0 afterwards
- [ ] Make sure the **first** dispatch still sees `designcomponent_SetBathy == 0`, so the ID and
      friction writes are unaffected. Order matters: dispatch 1 (ID + friction), then flag on,
      dispatch 2 (bathy), then flag off.
- [ ] Console-log the second dispatch once (like the existing
      `console.log('Adding Linear Structure to Bathy/Topo')`) for debuggability
- [ ] Sanity-check performance while dragging — one extra dispatch per painted frame should be
      invisible next to the sim loop; confirm `render_step` behavior is unaffected

**Exit criteria:** painting mangroves visibly changes bathymetry to the target elevation; water
responds (wetting/drying at the new edge); no console errors; Boussinesq runs stay stable for at
least a few thousand steps after painting.

**Notes:**
_(fill in after completion)_

---

### Phase 5 — Original-bed stash (idempotence + undo)

**Status:** NOT STARTED

`txDesignComponents.y/.z/.w` are unused and already round-trip through the shader. Use them to
store the pre-edit bed so that (a) taper blending is computed against a fixed reference rather
than the live bed, making repeated strokes idempotent, and (b) erasing a component can restore
the original bathymetry.

- [ ] On the first paint of a cell (component ID transitions from 0 to non-zero), stash the
      original `B.z/.x/.y` into `txDesignComponents.y/.z/.w`
- [ ] Compute the tapered target as a blend between `designcomponent_TargetElev` and the
      **stashed** original, never the live `txBottom` value
- [ ] Decide and document restore-on-erase behavior: when a cell's component ID is cleared, does
      the bed revert? (Recommended: yes, and it makes the feature safely reversible.) Note that
      there is currently no erase UI — component values are 1–10 only — so this may just be
      plumbing for later.
- [ ] Confirm the stash survives the texture export at `js/main.js:3650`
      (`downloadTextureData(device, txDesignComponents, ...)`) and note what the extra channels
      mean for any downstream consumer of that file

**Exit criteria:** painting the same spot 100 times produces the identical bed as painting it
once; original bed is recoverable.

**Notes:**
_(fill in after completion)_

---

### Phase 6 — Footprint and edge-taper reconciliation

**Status:** NOT STARTED

- [ ] Implement the real taper in `calc_component_bathy_elevation`: full target inside
      `0.5*R - designcomponent_EdgeTaper`, ramping to the stashed original bed at `0.5*R`
- [ ] Choose a taper default that is at least a few cells wide at typical `dx` — a taper narrower
      than the grid is the same as no taper
- [ ] Reconcile the three footprints now in play: ID disc (`0.5*R`, hard), friction Gaussian
      (`k = 4/R`, effectively `~0.25*R`), and the new bathy footprint. Either widen the friction
      Gaussian to match the disc or document the mismatch deliberately. **This changes existing
      behavior for all ten components — flag it for Patrick before shipping.**
- [ ] Test for spurious reflections off the perimeter: place a mangrove patch in an otherwise
      uniform-depth domain, run monochromatic waves, and look for perimeter-generated scatter in
      the wave-height field

**Exit criteria:** no visible perimeter artifact at the taper; footprint story documented.

**Notes:**
_(fill in after completion)_

---

### Phase 7 — Integration checks

**Status:** NOT STARTED

Each of these is a known coupling that the bathy edit touches.

- [ ] **`txBottomInitial`** — not updated by the existing bathy edit (there is a commented-out
      line and a note about prescribed motion at ~2534). It is the baseline for sediment
      bed-change. Decide whether a mangrove platform should shift that baseline; test with
      `useSedTransModel == 1` either way.
- [ ] **Sea level change** — paint mangroves, then change sea level, and confirm the platform
      shifts with the bed (relative sea-level rise) rather than tracking the water surface.
- [ ] **`txState`/`txNewState`** — the eta fix only lands in `txstateUVstar`, following existing
      precedent. Verify visually that nothing renders a stale free surface for a frame.
- [ ] **3D / Explorer view** — `shaders/fragment_testing.wgsl` and `vertex3D.wgsl` render from
      bathymetry; confirm the raised platform looks right in `viewType == 2` and that the mangrove
      texture (`textures/mangrove.jpg`, loaded at `js/main.js:727`) still maps sensibly.
- [ ] **Export/reload** — write out the bathymetry, reload it as an example input, and confirm the
      platform survives the round trip.
- [ ] **CelerisAgent** — `js/agent_controls.js` exposes design actions to the agent API. Add the
      new parameters there if the agent should be able to place mangroves programmatically;
      otherwise note explicitly that it cannot.

**Exit criteria:** each item either verified working or recorded as a known limitation.

**Notes:**
_(fill in after completion)_

---

### Phase 8 — Manual test matrix + docs

**Status:** NOT STARTED

No test framework exists; validation is by loading examples and watching the console.

- [ ] Run the feature across at least three examples with different characteristics: a steep
      bathymetry case, a flat shallow case, and one with wave breaking enabled
- [ ] Test both `NLSW_or_Bous == 0` and `>= 1` (the Boussinesq path exercises `UpdateTrid`)
- [ ] Test paint-over-land, paint-over-deep-water, and paint-across-the-shoreline
- [ ] Test with `useSedTransModel == 1`
- [ ] Confirm no console errors in any case, and no NaN bloom in the free surface after a few
      thousand steps
- [ ] Document the feature in `CLAUDE.md` / `AGENTS.md` (config coupling section — this adds a new
      instance of the three-layer coupling those docs describe: constant → uniform → shader)
- [ ] Stage **only** the edited paths (see the hygiene warning above), commit, and summarize the
      change for review

**Exit criteria:** matrix run and recorded; docs updated; clean reviewable commit on `mangroves`.

**Notes:**
_(fill in after completion)_

---

## Open questions for Patrick / David

- Should the mangrove platform be **flat** at the target elevation, or should it follow the
  existing bed slope offset to the target (a sloping intertidal platform is more realistic than a
  bathtub)? Current plan is flat — revisit if results look artificial.
- Is `set exactly` right when a mangrove is painted over existing high ground? It will excavate.
  Trivial to switch to raise-only later — one `max()`.
- Should the other nine components eventually get elevations too, and if so, is that the moment to
  refactor the flat `designcomponent_Fric_*` constants into a per-component table?
- Long term: is the goal mangrove geometry (this branch) or mangrove physics (canopy drag and
  porosity in Pass1/Pass2, rejected option D)?

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
| 4 | JS dispatch + texture copy block | DONE |
| 5 | Original-bed stash (idempotence + undo) | DONE |
| 6 | Footprint and edge-taper reconciliation | DONE |
| 7 | Integration checks (sed transport, sea level, export, 3D, agent API) | DONE |
| 8 | Manual test matrix + docs | DONE |

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

**Status:** DONE

This is where the feature becomes visible.

- [x] In the `whichPanelisOpen == 2` copy block's `else` branch (component-add path, ~line 2578),
      after the existing ID/friction copies: if the pending bathy decision (captured before
      dispatch 1, see below) is `1`, set `designcomponent_SetBathy = 1`, re-upload the uniforms,
      run a **second** `runComputeShader(...)` of the same pipeline, then the standard bathy
      follow-up — `txtemp_MouseClick → txBottom`, `txtemp_MouseClick2 → txstateUVstar`,
      `Updateneardry`, `txtemp_bottom → txBottom`, `UpdateTrid` when `NLSW_or_Bous >= 1` — then
      reset the flag to `0`.
- [x] **Found and fixed a latent bug from Phase 2 while implementing this**: Phase 2's if-chain set
      `calc_constants.designcomponent_SetBathy` directly from the mangrove enable flag *before*
      dispatch 1's uniform upload, so if a user had turned the mangrove "set bathy" toggle on,
      dispatch 1 (meant to be ID/friction only) would have carried `SetBathy=1` into the shader —
      corrupting the design-component-ID texture with raw elevation values. Never manifested
      during Phase 2/3 testing because the toggle defaulted to "No" throughout. Fixed by capturing
      `const designcomponent_SetBathy_pending = calc_constants.designcomponent_SetBathy` right
      after Phase 2's assignment, forcing `calc_constants.designcomponent_SetBathy = 0` before
      dispatch 1, and only consulting `designcomponent_SetBathy_pending` for the Phase 4 decision
      — exactly the "dispatch 1 sees 0, then flag on for dispatch 2" ordering this phase's
      checklist called for.
- [x] Second dispatch logs `'Setting Mangrove Bathy/Topo to Target Elevation'`; the `Updateneardry`
      follow-up logs `'Updating neardry & tridiag coef due to mangrove bathy set'`.
- [x] Performance: no separate check needed — this only fires while a mouse button is held over
      the canvas with the design panel open, same cadence as every existing click-update path, and
      was visually smooth while dragging during testing.

**Exit criteria:** painting mangroves visibly changes bathymetry to the target elevation; water
responds (wetting/drying at the new edge); no console errors; Boussinesq runs stay stable for at
least a few thousand steps after painting.

**Notes:**
Verified live (Claude in Chrome, macOS browser). Ventura Harbor, Boussinesq mode. Set Mangroves →
"also set bathymetry/topography... : Yes" → dragged a stroke on land. Console showed the full
per-frame sequence five times: `Updating Design Components` → `Setting Mangrove Bathy/Topo to
Target Elevation` → `Updating neardry & tridiag coef due to mangrove bathy set`, zero errors.
Switched `Property to Plot` to `Bathymetry/Topography (m)` and zoomed into the painted region: a
distinctly colored patch, matching the drag stroke's exact shape, is visible against the
surrounding terrain — confirming the target elevation was actually written to `txBottom`, not
just the design-component texture. Let the sim run ~8 more simulated minutes afterward with no
NaN bloom, no new console errors, and no visual artifacts at the patch edge (edge-taper shock
handling is still Phase 6 — none observed yet at this wave climate/footprint size, but the
Ventura Harbor example wasn't chosen to stress-test that). Same blob-splice approach used to keep
the diff to the ~19 real lines added.

---

### Phase 5 — Original-bed stash (idempotence + undo)

**Status:** DONE

`txDesignComponents.y/.z/.w` are unused and already round-trip through the shader. Use them to
store the pre-edit bed so that (a) taper blending is computed against a fixed reference rather
than the live bed, making repeated strokes idempotent, and (b) erasing a component can restore
the original bathymetry.

- [x] On first paint of a cell (`f == 1.0 && B_here.x == 0.0`, i.e. component ID transitioning
      from 0 to non-zero), stash the pre-edit `txBottom` values into `txDesignComponents.y/.z/.w`
      (`.z→.y`, `.x→.z`, `.y→.w`). Lives in the `else` (plain component-add) branch of the compute
      block, ~line 260 of `shaders/MouseClickChange.wgsl` — applies to all ten components sharing
      this texture, not just mangroves, matching the "mechanical to extend later" decision.
- [ ] **Not done — deferred to Phase 6, as that phase's own checklist specifies.** There is no
      taper yet: `calc_component_bathy_elevation` (Phase 3) returns `designcomponent_TargetElev`
      unconditionally inside the hard-edged disc, so it doesn't blend against *anything* today —
      live or stashed. Phase 5's exit criterion of idempotence under repeated strokes already holds
      for this reason alone (confirmed below), independent of the stash. The stash exists now so
      Phase 6 has a fixed reference ready when it adds the actual taper ramp.
- [x] **Decision: restore-on-erase should happen, recommended.** Not implemented — there is no
      erase UI (`designcomponentToAdd` is 1–10 only, no "0 = erase" option), so per the checklist's
      own allowance this is plumbing only. The stash data is sitting in the texture, ready for a
      future erase feature to read.
- [x] Checked the export path (`js/main.js:3680`,
      `downloadTextureData(device, txDesignComponents, 1, filename, readbackBuffer)`): the `1`
      argument is a 1-indexed **single-channel** selector (`File_Writer.js`'s `readTextureData`,
      `chanOffset = channel - 1`), not a channel count — this export writes only `.x` (the
      component ID) and silently drops `.y/.z/.w`. Also confirmed there is no re-import path for
      `current_designcomponents.bin` anywhere in `File_Loader.js` / `Model_Loaders.js` — these
      `current_*.bin` files are one-way debug dumps, not part of scenario save/load. So the stash
      not surviving this particular export is a non-issue: nothing reads the file back, and normal
      scenario persistence is a separate mechanism this phase didn't touch.

**Exit criteria:** painting the same spot 100 times produces the identical bed as painting it
once; original bed is recoverable.

**Notes:**
Verified live (Claude in Chrome, macOS browser, Ventura Harbor Boussinesq example). Shader
compiled cleanly with the stash branch added. Painted the same spot three separate times (5
mousemove events each, 15 total) with Mangroves + set-bathy enabled: all 15 fired the full
`Updating Design Components` → `Setting Mangrove Bathy/Topo to Target Elevation` → `Updating
neardry & tridiag coef due to mangrove bathy set` sequence, zero errors. Switched to the
`Bathymetry/Topography (m)` plot and confirmed the resulting patch is a single consolidated blob
matching the stroke shape — no growth, bleeding, or intensification from the repeated strokes,
confirming idempotence. (As noted above, idempotence currently follows from Phase 3's hard-edged
"set exactly" elevation function having no dependency on prior bed state at all — the stash isn't
load-bearing for *this* phase's exit criterion yet, but is exactly what Phase 6 needs to keep that
property once a taper is introduced.) Same blob-splice approach used to keep the diff to the ~11
real lines added.

---

### Phase 6 — Footprint and edge-taper reconciliation

**Status:** DONE

- [x] Implemented the taper in `calc_component_bathy_elevation` (~line 110 of
      `shaders/MouseClickChange.wgsl`): full `designcomponent_TargetElev` inside
      `inner_radius = max(0.0, outer_radius - designcomponent_EdgeTaper)`, linear `mix()` to the
      **stashed** original bed (Phase 5, read from `txDesignComponents.y/.z/.w` at the call site)
      across `inner_radius → outer_radius = 0.5*designcomponent_Radius`, unchanged (`current_bed`)
      beyond `outer_radius`. Ramping to the stash rather than the live bed is what keeps repeated
      strokes idempotent once a taper exists (the concern flagged in "Constraints that will bite
      you" #2) — this is the payoff for Phase 5's plumbing.
- [x] Bumped the `designcomponent_EdgeTaper` default from the Phase 2 placeholder (`2.0`) to
      `5.0` m — a few cells wide at the `dx = 1–5` m range typical of coastal wave examples.
      Documented in-line that this is still effectively zero taper at the coarse-grid tsunami/AK
      examples (`dx` up to 200 m) — no per-example auto-scaling was added; flagging the limitation
      was judged sufficient per the plan's own "narrower than the grid = no taper" framing.
- [ ] **Footprint mismatch: documented, not changed — needs Patrick's sign-off before shipping,
      exactly as the checklist itself said not to do unilaterally.** Three footprints now coexist:
      the ID disc and the new bathy disc share `0.5*designcomponent_Radius` (hard edge, or tapered
      for bathy) — those two were already aligned as of Phase 3 by construction, since the bathy
      footprint was modeled directly on the existing ID disc radius. The **friction Gaussian**
      (`k = 4/designcomponent_Radius`, ~2% amplitude at `r = 0.5*R`, effectively full-strength only
      out to roughly `r ≈ 0.25*R`) is still narrower than both. Concretely, with the Phase 6 taper
      in place: the outer ~half of the visible bathy platform (between the friction Gaussian's
      effective edge and `0.5*R`) is raised/tapered bed with **not-yet-full friction coverage**,
      and the taper ring specifically sits entirely outside the Gaussian's meaningful range. This
      preexisted for all ten components before this branch (friction vs. ID mismatch); adding a
      third, larger-radius footprint (bathy) makes the friction Gaussian look comparatively
      narrower still. **Not fixed here** because widening it changes rendered friction for every
      existing component/example, which the plan explicitly reserves for Patrick's approval.
- [x] Tested for perimeter reflections: loaded the "Toy Problem, wind waves" example
      (`examples/Toy_Config`, flat `-10` m bed near the west/wavemaker boundary, `waves.txt`
      forcing a monochromatic wave — amplitude 0.5 m, period 10 s, direction 0), reduced
      `designcomponent_Radius` to `20` m and `designcomponent_Elev_Mangrove` to `-5` m (kept the
      patch submerged, to avoid conflating wetting/drying effects with pure taper-edge scattering),
      and painted a single small patch in the flat region away from both the wavemaker and the
      natural shoreline slope.

**Exit criteria:** no visible perimeter artifact at the taper; footprint story documented.

**Notes:**
Verified live (Claude in Chrome, macOS browser). Shader compiled cleanly with the taper code.
Switched to the `Bathymetry/Topography (m)` plot and confirmed the taper renders as a smooth
radial gradient (bright center fading outward) rather than the earlier Phase 3/4 hard-edged blob —
visual confirmation the ramp math is live. Switched to `Free Surface Elevation (m)` and let the
monochromatic wave train interact with the patch: observed a smooth fan-shaped diffraction
wake/shadow pattern behind the patch, with no jagged, blocky, or checkerboard artifacts localized
at the taper ring — the pattern reads as ordinary physical diffraction off a submerged obstacle,
not a numerical artifact from the edge treatment. Also checked `Significant Wave Height (m)`;
it showed a bright transient blob right at the patch, but this is expected — that's a running
statistic still re-converging moments after a fresh bathy edit, not evidence of instability.

**Caveat on rigor:** this was a qualitative visual check (one example, one patch size, one
snapshot in time), not a quantitative wave-height-difference-from-baseline comparison (i.e. no
side-by-side "taper vs. hard edge" or "with vs. without patch" run). Given the tooling available
(screenshots via browser automation, no data-export/diffing pipeline set up), a rigorous
quantitative version of this check is a reasonable follow-up before shipping, but the qualitative
result is a real, honest observation, not a guess.

---

### Phase 7 — Integration checks

**Status:** DONE

Each of these is a known coupling that the bathy edit touches.

- [x] **`txBottomInitial`** — **decision: deliberately left unupdated**, matching the existing
      `surfaceToChange==1` precedent (`js/main.js:2548`, itself a commented-out line with the same
      unresolved doubt). Added a matching commented-out line + explanation in the mangrove branch
      (`js/main.js` ~2590). Grounded in the actual shader math, not guessed: `txBottomInitial` is a
      one-time snapshot taken at `frame_count==0` (`js/main.js:2291`) and is read in exactly one
      place that matters, `shaders/SedTrans_UpdateBottom.wgsl:117`
      (`dB_cumulative = B_new - textureLoad(txBottomInitial, idx, 0)`) — a **diagnostic/bookkeeping
      output** (`txBotChange_Sed`, rendered as "Depth Change due to Sed Transport",
      `surfaceToPlot==21`), not an input to the erosion/deposition rate physics itself (Pass1/Pass3
      read live `txBottom` directly, never `txBottomInitial`). Consequence of not updating it: that
      diagnostic (and its export, `current_SedTransDepthChange.bin`) will show a permanent
      step-change at every mangrove platform, indistinguishable from real sediment-transport
      accretion/erosion. No physics-breaking effect, no crash, no divergence — confirmed live:
      enabled `useSedTransModel` via the agent API and painted a mangrove platform, full clean
      dispatch sequence, zero console errors.
- [x] **Sea level change** — verified live: painted a mangrove platform at target elevation `5.00`
      m (confirmed via hover tooltip reading exactly `5.00`), then raised sea level by `+2` m via
      the "Modify Sea Level & Edit Bathy/Topo" panel, then re-hovered the same world coordinate —
      bathy read exactly `3.00` m (`5 - 2`). The platform shifts with the bed as designed; nothing
      needed changing, since the mangrove `TargetElev` is absolute and sea-level change is a
      uniform shift applied to all of `txBottom` including the just-painted cells.
- [x] **`txState`/`txNewState`** — **confirmed, via code reading, that a real one-sub-step stale
      window exists** — but it is shared by *every* bathy-edit path (`surfaceToChange==1`, linear
      structures, mangroves alike), not introduced by this branch. The click path writes only
      `txstateUVstar` (`js/main.js:2591`); `txState` is refreshed only at the end of each physics
      `frame_c` iteration (`js/main.js:2930-2931`, `txNewState → txState`). So the first `Pass1`
      invocation after any bathy edit computes `H = eta − B` against the *new* `B` but the *old*
      `txState.eta`, self-healing within 1-2 sub-steps. A second, distinct mismatch: the click
      block's own `UpdateTrid` follow-up reads `current_stateUVstar` (a texture the click path
      never touches), not the just-updated `txstateUVstar`. No visual glitch was observed in any
      of the live tests run across Phases 4-7 (dozens of paint events, several `render_step`
      cycles per frame in every example used), consistent with this being a sub-step-scale, largely
      imperceptible effect rather than a visible one-frame stale render.
- [x] **3D / Explorer view** — **corrected a wrong premise in the original checklist**:
      `shaders/fragment_testing.wgsl` is dead code, never loaded by `js/main.js`; the live pipelines
      use `shaders/fragment.wgsl` + `shaders/vertex3D.wgsl` for both 2D and Explorer (`viewType==2`)
      rendering. Component-ID-driven texturing in `fragment.wgsl` (component 3 → `mangrove.jpg`,
      loaded at `js/main.js:730` into `txSamplePNGs` layer 3, branch at `fragment.wgsl:650-656`) is
      pre-existing, generic infrastructure keyed off the same `txDesignComponents.r` channel the
      paint operation already writes — no new plumbing was needed or added. Verified live: switched
      to `viewType==2`, the 3D scene rendered cleanly (skybox, terrain, water) with zero console
      errors using bathymetry that included painted mangrove platforms. Did not visually confirm
      the mangrove texture itself at close range (camera was pointed away from the painted patches
      and repositioning it was out of scope for this check) — the texturing mechanism is verified
      by code inspection, not by eye, for this specific item.
- [x] **Export/reload** — **no round-trip exists today, and this is a pre-existing, general
      limitation, not mangrove-specific.** The only bathymetry export
      (`js/main.js:3670-3672`, "Property to Write to File" → "Bathymetry/Topography (m)") writes
      `current_bathytopo.bin`, a headerless raw `Float32Array` binary
      (`js/File_Writer.js:downloadTextureData`/`readTextureData`). The only bathymetry *import*
      (`Load Bathymetry Data File`, `js/File_Loader.js:loadDepthSurface`) expects a whitespace-
      delimited ASCII grid (`.split('\n')`, matching every example's `bathy.txt`). These formats
      are incompatible and there is no in-app conversion step — mirrors exactly what Phase 5 already
      found for `current_designcomponents.bin`. Verified live: triggered the export button with a
      painted platform present, zero console errors (confirms the readback mechanism itself
      doesn't break on mangrove-modified `txBottom`). Did **not** verify byte-level correctness of
      the downloaded file's contents, since the browser session's Downloads folder isn't
      inspectable from this environment — the live hover-tooltip checks elsewhere in this phase
      already confirm the underlying GPU texture (`txBottom`) holds the correct values, which is
      what this export reads directly.
- [x] **CelerisAgent** — added `design.place_mangrove_platform` (`js/agent_controls.js`, function
      `placeMangrovePlatform`, registered in `applyCommand` and `validCommands`), args
      `{x_m, y_m, elevation_m, radius_m?}`. Unlike `setSurfaceComponent` (arms paint mode only,
      requires a follow-up canvas click) this fires the paint immediately in one call, modeled on
      `requestAddLinearStructure`'s fire-on-call pattern — appropriate here because there's no
      multi-step endpoint state to validate first, unlike linear structures. Converts world meters
      to the grid-index units `xClick`/`yClick` actually expect (`x_m / dx`, `y_m / dy`) — got this
      wrong on the first attempt during manual verification (assumed meters), corrected by reading
      `js/main.js:3954-3955`'s existing mouse-to-`xClick` conversion. One call places exactly one
      circular/tapered patch, same as one mouse click; painting a larger or multi-location area
      still needs multiple calls, matching how a human dragging the mouse fires repeated
      `click_update` events. Verified live via `window.CelerisAgentControls.applyCommand(...)` in
      the browser console: placed three platforms at distinct world coordinates across two
      examples, each producing the exact expected constants (`designcomponentToAdd=3`,
      `designcomponent_Elev_Mangrove`, `designcomponent_SetBathy_Mangrove=1`, correctly-converted
      `xClick`/`yClick`) and the identical clean dispatch sequence seen throughout manual testing;
      confirmed via hover tooltip that the resulting bathy value at the target coordinate matched
      the requested `elevation_m` exactly.

**Exit criteria:** each item either verified working or recorded as a known limitation.

**Notes:**
Research for this phase (code reading across `js/main.js`, `js/File_Writer.js`, `js/File_Loader.js`,
`js/agent_controls.js`, and the `SedTrans_*`/`fragment`/`vertex3D` shaders) was delegated to an
Explore subagent to keep this phase's context manageable; findings were spot-checked directly
(grepped exact line numbers, read the cited code) before being written up here, and one correction
was made along the way (`fragment_testing.wgsl` being dead code, not the live 3D shader as the
original checklist assumed). All live verification (sea level, sediment transport, 3D view,
export trigger, CelerisAgent) was done directly via the Claude in Chrome connection, not delegated.

---

### Phase 8 — Manual test matrix + docs

**Status:** DONE

No test framework exists; validation is by loading examples and watching the console.

- [x] Ran across three examples with different characteristics (plus Ventura Harbor and Toy_Config
      already covered in Phases 4-7):
      - **Steep bathymetry**: Scripps Canyon (`dx=15` m, `base_depth=500` m, Boussinesq,
        breaking on). Also incidentally exercises the Phase 6 "taper narrower than the grid is the
        same as no taper" caveat, since `EdgeTaper=5` m `< dx=15` m.
      - **Flat shallow**: Santa Cruz Harbor tsunami (`dx=2` m, `base_depth=9` m, `NLSW_or_Bous=0`).
      - **Wave breaking enabled**: Ventura Harbor and Toy_Config (both `useBreakingModel=1`,
        already tested extensively in Phases 4/6/7).
- [x] `NLSW_or_Bous == 0`: Santa Cruz Harbor tsunami. Confirmed via console — after painting,
      `Setting Mangrove Bathy/Topo to Target Elevation` appeared but `Updating neardry & tridiag
      coef due to mangrove bathy set` did **not** (that log line and the `UpdateTrid` dispatch it
      guards are both inside `if (NLSW_or_Bous >= 1)`), i.e. directly confirms `UpdateTrid` is
      correctly skipped for the non-Boussinesq path.
      `NLSW_or_Bous >= 1`: covered by every other example in this branch's testing (all Boussinesq).
- [x] Paint-over-land, paint-over-deep-water, paint-across-the-shoreline: all three done in one
      pass on Santa Cruz Harbor tsunami's river-channel domain — a tan/land patch, a teal/water
      patch, and a drag straddling the channel bank. All three rendered as clean, stable, distinct
      platforms (screenshot-confirmed); 15 painted frames total, zero console errors.
- [x] `useSedTransModel == 1`: done in Phase 7 (Ventura Harbor) — no crash, confirmed only the
      documented "Depth Change due to Sed Transport" diagnostic artifact, not a physics issue.
- [x] No console errors in any case: confirmed throughout — the one exception seen during this
      phase (`TypeError: Cannot read properties of null (reading 'createCommandEncoder')`) fired
      at the exact timestamp of an example-reload transition, before the mangrove command that
      followed it ran; it's the old frame loop hitting a null `device` mid-teardown, a pre-existing
      reload-transition race unrelated to this branch — not reproduced by anything the mangrove
      code does.
      No NaN bloom: Santa Cruz Harbor tsunami ran ~9.7 simulated minutes after painting three
      patches with no degradation; Scripps Canyon ran with a stable, unchanged bathy reading after
      20+ seconds of real time on genuinely steep terrain. Did not push any single run to literal
      "a few thousand steps" of wall-clock waiting (impractical within this session), but every run
      observed was monotonically stable with no visual or numeric sign of divergence.
- [x] Documented in both `CLAUDE.md` and `AGENTS.md` (identical "Config Coupling" sections in each)
      — added a paragraph describing the mangrove feature as a worked example of the three-layer
      coupling pattern, adapted for parameters delivered through the `MouseClickChange` per-dispatch
      uniform buffer rather than a `Handler_*.js` compile-time pipeline override.
- [x] Staged and committed only the edited paths per the hygiene warning, one commit per phase
      throughout (see `git log` on this branch); this phase's own commit follows this entry.

**Exit criteria:** matrix run and recorded; docs updated; clean reviewable commit on `mangroves`.

**Notes:**
All live testing in this phase used the Claude in Chrome connection (macOS browser). Every test
in the matrix passed with no code changes required — Phase 8 surfaced no new bugs, only the one
pre-existing, unrelated reload-transition exception noted above. The branch is functionally
complete through all 8 planned phases; remaining items are the "Open questions for Patrick /
David" below, which are product decisions, not implementation gaps.

---

## Post-review fixes

### BUG-1 — Edge taper carved slopes inside overlapping footprints (fixed 2026-08-25)

**Reported by David** with a screenshot: a single painted mangrove disc renders as a clean flat
platform, but a cluster of overlapping discs is cut through by dark crescent arcs running back down
to the original deep bed — "the slope is created even when it is not needed."

**Cause.** `calc_component_bathy_elevation` defined the taper against the **individual disc of the
current stroke**, ramping from the target to the Phase 5 stashed pre-edit bed between `inner_radius`
and `outer_radius`. Painting is continuous and discs overlap heavily, so a later stroke's ring
routinely lands on cells an earlier stroke had already flattened, and drags them back toward their
untouched (deep) elevation. Every stroke's perimeter therefore engraves a groove across the platform
the previous strokes built.

The component ID is no discriminator: dispatch 1 stamps the ID over the whole disc *before*
dispatch 2 reads it, so the current stroke's ring cells are indistinguishable from earlier ones.

**First attempt (insufficient — recorded so it is not retried).** Keeping whichever of the tapered
value and the live bed was already nearer the target. It removes the obvious grooves but not all of
them: a cell can land in the taper ring of *every* stroke that ever touches it and so never reach
the target at all. A 6-disc cluster simulated at `R=30, taper=6` still left 27 interior cells below
0 m, min −2.4 m. Any per-disc rule has this failure mode.

**Fix.** Define the taper from the **union footprint** instead of from each disc. `txDesignComponents.x`
is written by dispatch 1 and copied back before dispatch 2 runs, so it already includes the current
stroke. A new `footprint_edge_distance(idx, ox, oy)` measures the distance from the evaluation point
to the nearest cell *outside* the component footprint, over a window sized to `EdgeTaper` (capped at
12 cells per side); the elevation is then

```wgsl
let w = clamp(1.0 - d / taper, 0.0, 1.0);
return mix(target_elev, stashed_bed, w);
```

so the slope follows the outline of the union and the interior is always exactly the target. `(ox, oy)`
offsets the evaluation point by half a cell for the north/east face channels.

Because the result depends only on (ID map, stash, target) — never on the live bed or on stroke order —
it is idempotent, order-independent, and **self-healing**: every paint event recomputes the whole
footprint from the stashed bed, so a cell that was on the edge earlier is flattened once later strokes
make it interior. Simulated on the same 6-disc cluster: interior min = target exactly, 0 cells below 0 m,
identical under repeated and reversed stroke order.

### BUG-2 — `target` is a WGSL reserved keyword (fixed 2026-08-25)

The first attempt at BUG-1 introduced `let target = globals.designcomponent_TargetElev;`. `target` is
**reserved** in WGSL, so `createShaderModule` fails and the entire `MouseClickChange` pipeline never
builds — which is why that attempt appeared to change nothing at all rather than partially working.
Renamed to `target_elev`.

**Verification.** The edited shader was compiled with naga/wgpu-native and used to build a real
compute pipeline against the same 8-entry bind-group layout as `Handler_MouseClickChange.js`
(uniform + 5 sampled textures + 2 `rgba32float` write-only storage textures): clean, no messages.
Worth repeating whenever this file changes — there is no build step here, so a WGSL error only shows
up as a console exception at runtime.

**Files:** `shaders/MouseClickChange.wgsl` only.

**Still to verify in-browser:** paint an overlapping cluster and confirm the interior is uniform with
a taper only around the outside of the merged patch; confirm an isolated disc is unchanged. Note that
cells whose stash was captured *after* the buggy version had already dug a groove keep that grooved
value as their reference — start from a freshly loaded example for a clean comparison.

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

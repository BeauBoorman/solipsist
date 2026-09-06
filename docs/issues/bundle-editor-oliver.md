# Bundle boris-editor (+ UI) and oliver with the app

**Track:** Engine bundling / release honesty
**Milestone:** post-M18 — follows the engine-settings-truth residual (#292)
**Issue:** file on `drawmeanelephant/solipsist` (next number)
**Lane:** `scripts/embed-boris.sh` + `Sources/Companions/Editor/EditorServerFactory.swift` + `Sources/Engine/OliverBinary.swift` (+ release gate)

## Problem

A fresh `Solipsist.app` ships exactly one engine artifact —
`Contents/Resources/boris`. The two processes the app actually shells out to
besides it are silently absent:

1. **`boris-editor`** (M6 author companion, A14): `EditorServerFactory.launch`
   throws `editorBinaryNotFound` unless `SOLIPSIST_BORIS_EDITOR_BIN` is set or
   a dev checkout happens to sit at a CWD-relative path. The Settings pane
   ("Engine") then reports the editor host as missing on a clean machine.
2. **The editor UI** (`editor/ui/dist`, compiled Svelte): even with a binary,
   nothing passes `--ui-dir`. `boris-editor` defaults to `editor/ui/dist`
   relative to its CWD — and Solipsist sets CWD to the user's *project root*,
   where that path never exists. Result: the host starts, the URL connects,
   and every `/` + `/assets/*` request 404s.
3. **`oliver`** (compose preview, `oliver render --from …`): `OliverBinary`
   falls through bundle → sibling → dev-checkout candidates and returns nil
   on a clean machine; compose preview reports "oliver renderer not found".

`scripts/embed-boris.sh` already *intends* to bundle both (companion loop +
`bundle_oliver`), but three gaps defeat it:

- The companion search roots are `$SRCROOT/../boris`-relative
  (`${BORIS_REPO_DIR:-$SRCROOT/../boris}/zig-out/bin`). From a worktree
  (`…/.t3/worktrees/solipsist/…`) or with `SOLIPSIST_BORIS_BIN` pointing at a
  real checkout elsewhere, that directory does not exist — companions are
  skipped with no warning. `BORIS_REPO_DIR` is read but never documented in
  `AGENTS.md` / `Makefile`, so nobody sets it.
- `zig build` at the boris root does **not** produce `boris-editor` (separate
  `editor/build.zig`; never built in this flow) and never builds
  `editor/ui/dist` (needs `npm ci && npm run build` in `editor/ui`). There is
  nothing to bundle even when the directory resolves.
- Same worktree problem for oliver: candidates are `$SRCROOT/../oliver`-style
  paths; the real checkout (`/Users/tbuddy/t3/swift/oliver`) is never
  consulted, and `SOLIPSIST_OLIVER_BIN` is the only override.

## Verified current state

- `scripts/embed-boris.sh:115-147` — companion loop copies `boris-editor`,
  `boris-package`, `boris-source-rag`, `boris-content-audit` from kit dirs or
  `${BORIS_REPO_DIR:-$SRCROOT/../boris}/zig-out/bin`. `boris/zig-out/bin/`
  today holds `boris`, `boris-job-runner`, `boris-package`,
  `boris-source-rag` (+ wasms) — **no `boris-editor`**.
- `scripts/embed-boris.sh:149-196` — `find_oliver` / `bundle_oliver`;
  absence is a notice, not a failure.
- `Sources/Companions/Editor/EditorServerFactory.swift:32-62` — resolution:
  env → sibling-of-engine → bundle → CWD-relative dev candidates. No UI dir
  anywhere.
- `Sources/Engine/EditorServer.swift:34-56` — `uiDir` is plumbed to
  `--ui-dir` but defaults to nil and no caller passes it.
- `Sources/Engine/BorisEngine.swift:604-618` — `editorStart(..., uiDir: nil,
  ...)`.
- `Sources/Engine/OliverBinary.swift:12-50` — env → `Resources/oliver` →
  sibling-of-boris → CWD-relative dev candidates.
- boris `editor/src/main.zig:21` — `--ui-dir` defaults to `editor/ui/dist`
  (CWD-relative); `server.zig:657-662` serves `/` + `/assets/*` from it.
- A Debug build from this worktree produces
  `Solipsist.app/Contents/Resources/{boris,AppIcon.icns,Assets.car,help.md}`
  — no `boris-editor`, no `oliver`, no UI dir. (Observed 2026-09-06.)

## Scope

### Must land

- `embed-boris.sh` bundles, on every non-skipped build:
  - `boris-editor` into `Resources/` (same sign path as `boris`);
  - the compiled editor UI (`editor/ui/dist`) into `Resources/` (e.g.
    `Resources/editor-ui/`), preserving the `index.html` + `assets/` layout
    the host serves;
  - `oliver` into `Resources/` (same sign path).
- The script **fails the build** when any of the three is missing (same
  posture as the engine: a release without them is a silent failure), except
  under the existing `SKIP_EMBED_BORIS=1` opt-out.
- Lookup honours explicit env overrides first:
  `SOLIPSIST_BORIS_EDITOR_BIN`, `SOLIPSIST_EDITOR_UI_DIR`,
  `SOLIPSIST_OLIVER_BIN`, then `BORIS_REPO_DIR` /
  `OLIVER_REPO_DIR` checkouts (document both in `AGENTS.md` + `Makefile`
  comment), then the existing kit/sibling fallbacks.
- When the boris checkout has no built editor, the script builds it
  (`zig build --build-file editor/build.zig`, in `BORIS_REPO_DIR/editor`) —
  mirroring how it already builds the engine. UI `dist/` is **not**
  npm-built by the script (needs node + network); a missing `dist/` is a
  hard error telling the user to run `npm ci && npm run build` in
  `editor/ui`.
- Runtime: `EditorServerFactory.launch` resolves the bundled UI dir
  (`Bundle.main.url(forResource: "editor-ui" …)`, then
  `SOLIPSIST_EDITOR_UI_DIR`) and passes it as `uiDir`, so `--ui-dir` points
  at the bundle. `OliverBinary` / editor-binary resolution already checks
  `Resources/` first — no change needed there beyond the bundle existing.
- Settings Engine pane reports all three (it already renders resolved
  paths — verify green on a clean `make build` with no env overrides).

### Nice-to-have (not gate)

- Also bundle `boris-job-runner` (ships in `zig-out/bin/`, currently
  ignored by the companion loop).
- `boris --version` / `boris-editor --version` / `oliver --version`
  provenance line in the build log.
- Release-CI wiring for the new env vars (discrete-arch editor/oliver).

### Must not land

- Reimplementing Boris/editor/Oliver semantics in Swift (subprocess
  boundary stays).
- Patching the boris or oliver repos from here (build them, never edit).
- npm-installing the editor UI as part of `make build` (networked,
  slow, surprising — error with instructions instead).
- Changing the `SKIP_EMBED_BORIS=1` CI compile-job escape hatch.

## Gate

Clean checkout, no engine env vars set:
`make build` succeeds → `Contents/Resources/` contains `boris`,
`boris-editor`, `oliver`, `editor-ui/{index.html,assets/…}` → launch the app
with a fixture project → Editor companion connects and renders the shell
(no 404s) → compose preview renders via bundled oliver → Settings/Engine
shows all three binaries present → `make test` + `make lint` green.

## Tests

- Embed-script level: fixture `BORIS_REPO_DIR`/`OLIVER_REPO_DIR` with stub
  binaries + stub `editor-ui/` → run `embed-boris.sh SRCROOT DEST` →
  assert all artifacts land executable (new `ContractTests` case or a
  `scripts/` self-test — whichever fits the harness; keep it hermetic, no
  network, no real builds).
- `testEditorFactoryPassesBundledUiDir` — bundled `editor-ui` present →
  launch args contain `--ui-dir <bundle path>`.
- `testOliverResolvesToBundledBinary` — `Resources/oliver` present → located
  without env vars.
- Existing `EditorServer` arg test still passes with `uiDir == nil`.

## Edge cases

- `SKIP_EMBED_BORIS=1` (CI compile job): no failure, no bundling — unchanged.
- Ad-hoc vs release signing: companions + oliver + UI files need no signing,
  binaries follow the existing `bundle_and_sign` path.
- `editor/ui/dist` missing in the boris checkout: hard error with the exact
  `npm ci && npm run build` remediation, not a silent editor-without-UI.
- Worktree builds (`SRCROOT` not a sibling of checkouts): env vars are the
  documented path; log the resolved provenance (`embed-boris: bundled
  boris-editor (provenance: …)`) so misconfig is visible.

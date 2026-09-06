# Solipsist — Agent Operating Manual

Read this first. Then [`docs/ROADMAP.md`](docs/ROADMAP.md) and
[`docs/HARNESS.md`](docs/HARNESS.md). Next work is one card from
[`docs/cards/`](docs/cards/README.md).

## What this is

Native macOS SwiftUI app. Boris is the engine — a subprocess, never a
library. We decode its versioned JSON contracts and host the surfaces
we refuse to write (`watch --serve`, `boris-editor`).

**Baseline:** afterparty `boris/0.8.1`. **Pin:** `bf464a0` (kit
metadata in `vendor/boris-agent-kit/`). Contains A1/A14/A7 + A3/A4/A13
(boris#648 / #643 / #642 / #641) **plus A15 `open=` (boris#649) and
A5 `validate --watch` (boris#647)**.

## Hard boundaries

1. Never touch the `boris` repo. Issues live in `docs/issues/` and are
   filed on GitHub — never a PR, never a patch to boris.
2. Never reimplement Boris semantics in Swift.
3. Never silently ignore diagnostics or exit codes.
4. Never mutate the user’s content tree except on an explicit save.
5. The subprocess boundary is a feature. One `Process?` slot in
   `BorisEngine`. Cancel = `Process.terminationReason == .uncaughtSignal`.

## Doc tree

| File | Purpose |
|------|---------|
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Goals, milestones, capability coverage |
| [`docs/HARNESS.md`](docs/HARNESS.md) | Spatial model + directory lanes |
| [`docs/MISSION.md`](docs/MISSION.md) | One-page why |
| [`docs/BORIS-CAPABILITIES.md`](docs/BORIS-CAPABILITIES.md) | What the engine can do |
| [`docs/ENGINE-CONTRACTS.md`](docs/ENGINE-CONTRACTS.md) | Probed machine contracts |
| [`docs/cards/`](docs/cards/) | Grind-lane briefs |
| [`docs/cards/parallel/`](docs/cards/parallel/) | External agent — PR cop, Boris issues, busy cards off the grind paths |
| [`docs/issues/`](docs/issues/) | Ready-to-paste boris issues |

## Build

```bash
make tools && make generate && make build
SOLIPSIST_BORIS_BIN=SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin/boris \
  make run-spike
```

Engine checkouts (boris + oliver) resolve via `BORIS_REPO_DIR` /
`OLIVER_REPO_DIR` — required from worktrees — else derived from
`SOLIPSIST_BORIS_BIN` inside a checkout, else `../boris` / `../oliver`
siblings. `make build` bundles boris, boris-editor + editor-ui, and oliver
into `Resources/`; a missing piece fails the build (`SKIP_EMBED_BORIS=1`
opts out). Overrides: `SOLIPSIST_BORIS_EDITOR_BIN`,
`SOLIPSIST_EDITOR_UI_DIR`, `SOLIPSIST_OLIVER_BIN`.

Never hand-edit `Solipsist.xcodeproj` — edit `Project.yml`.

## Git

- `main` is the clean merge target. Feature work is a branch + PR.
- Never `git add -A`. Never stage `SUPPORT-NOT-FOR-GITHUB/`.
- Never commit files you did not change.
- `boris/` is never touched by git operations from this repo.

## Milestones

M0 bootstrap ✅ · M1 spike ✅ · M2 chassis ✅ · **P** withdrawn ·
**M3** play & inspect ✅ · **M4** coordinate ✅ · **M5** preview ✅
· **M6** author ✅ · **M7** outputs ✅ · **M8** publish ✅ · **M9**
ship ✅ ([#78](https://github.com/drawmeanelephant/solipsist/issues/78))
· **M10** Mail body ✅
([#98](https://github.com/drawmeanelephant/solipsist/issues/98) —
Settings / mailboxes / reading / compose #106)
· **M11** prove the Mail body ✅
([#123](https://github.com/drawmeanelephant/solipsist/issues/123) —
Help audit + test pass)
· **M12** clone ✅
([#131](https://github.com/drawmeanelephant/solipsist/issues/131) —
Settings / File clone verb, sandbox-safe git)
· **M13** graph folders ✅
([#142](https://github.com/drawmeanelephant/solipsist/issues/142) —
#144/#145/#146)
· **M14** watch contract ✅
([#143](https://github.com/drawmeanelephant/solipsist/issues/143) —
#147/#148) · **M15** GitHub source ✅ (#179, PRs #180–#184) ·
**M16** write the remote ✅ (#185, PRs #187–#190) · **M17** Pull
Requests mailbox ✅ (#192, PRs #194–#196) · **M18** Siri drafts ✅
(PR [#294](https://github.com/drawmeanelephant/solipsist/pull/294) —
App Intents + on-device FoundationModels, macOS 27).
The milestone-10 editor polish batch (#225–#238) and the
accessibility tracker (#236 + children #239–#243) are merged.
The Apple-account ship blockers #110 / #111 are closed. The
tracker is empty.

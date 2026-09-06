# WYSIWYG Compose — Visual Editing Spike & Op Contract

| Field | Value |
|-------|--------|
| **Title** | WYSIWYG Compose — Visual Editing Spike & Op Contract |
| **Author** | Solipsist design lane (dme) |
| **Date** | 2026-09-06 |
| **Status** | Spike (proposed) |
| **Repo** | [drawmeanelephant/solipsist](https://github.com/drawmeanelephant/solipsist) |
| **Parents** | [`ROADMAP.md`](ROADMAP.md) §3 v1-must-not (no homegrown renderer) · [`AGENTS.md`](../AGENTS.md) boundaries |

## What this is

The compose window today is a textarea + Oliver preview: the author edits
markup and *reads* rendered output. This spike adds visual editing — typing
into the rendered surface — for **one node type** (the plain single-line
paragraph) and pins the **markup op contract** every further node type
reuses. It is a spike, not the finished editor: the contract and the
boundaries are the deliverable, the paragraph proves them end to end.

## Locked rules (do not reopen)

1. **No parallel document model.** The DOM inside the visual surface is
   *ephemeral paint*, exactly like the highlighter's colored attributes.
   `ComposeDocument.text` stays the single source of truth.
2. **Oliver stays the only renderer.** The visual surface loads Oliver's
   fragment through the same sandboxed-WKWebView document assembly as the
   preview pane (#230). Nothing in Swift parses markup semantics.
3. **Visual edits are markup ops.** A DOM edit event is translated into a
   pure buffer splice — the same posture as the #263 formatting verbs,
   which are marker transforms derived from Oliver's documented surface,
   never a grammar.
4. **The block map is a conservative sniff, never a parse.** Line shape
   and marker prefixes classify blocks, mirroring `ComposeHighlighter`'s
   documented posture. When classification is uncertain the block is
   non-editable; when source/rendered alignment cannot be *verified*, the
   visual surface disables itself and falls back to the plain preview.
5. **Never guess silently.** Unmappable DOM edits are discarded at the next
   reconcile (the buffer is truth); the DOM is never treated as authority.

## The op contract

### Visual edit event (JS → host)

The contenteditable surface emits one JSON message per `beforeinput`
(WebKit, `contenteditable="plaintext-only"` so paste and typing are plain
text by construction):

```json
{ "blockIndex": 3, "inputType": "insertText",
  "start": 12, "end": 12, "data": "e" }
```

- `blockIndex` — index among the rendered document's block-level children
  (marked `data-block` by the host after load; the host owns the numbering).
- `start`/`end` — UTF-16 code-unit offsets **within the block's rendered
  text**. For editable blocks (below) rendered text equals the block's
  source line text verbatim, so the offsets are buffer-relative after the
  block-map translation. Collapsed range = caret.
- `data` — the text the input inserts, if any.
- The event is *not* `preventDefault()`-ed: the browser applies its own
  mutation and keeps the caret; the host mirrors the same edit into the
  buffer. Drift between the two is corrected at reconcile (below).

Swift mirror: `ComposeVisualEditEvent` (`Decodable`, pure value).

### Markup ops (host-side, pure)

`ComposeMarkupOp` is the closed set of buffer mutations visual editing may
produce. Every op is a value; application is a pure function:

```swift
enum ComposeMarkupOp: Equatable {
    case insertText(String, at: Int)   // UTF-16 buffer offset
    case replaceText(NSRange, String)  // selection replace / paste / IME commit
    case deleteText(NSRange)           // backspace, forward-delete, cut
}
```

- **Derivation** — `ComposeMarkupOp.derive(from:in:blockMap:)` maps a
  visual event onto an op or returns `nil` (unmappable):
  - `insertText` / `insertReplacementText` / `insertFromPaste` /
    `insertCompositionText` → insert at caret or replace the extent.
  - `deleteContentBackward` / `deleteContentForward` with an extent →
    delete the extent; collapsed → delete one grapheme before/after the
    caret (surrogate-pair aware — never split one).
  - Paragraph breaks (`insertParagraphBreak`, `insertLineBreak`) are
    **unmappable in the spike** (a visual paragraph split is a block-level
    restructure, follow-up card); Enter is also intercepted in JS so the
    DOM never produces one.
  - Anything unrecognized → `nil`.
- **Application** — `applied(to:)` returns the new buffer and the
  resulting caret offset (UTF-16). The caret is remembered for
  reconcile-time restoration; the buffer splice flows through
  `ComposeDocument.text.didSet` so dirty state, word count, and language
  detection behave exactly as if the author typed in the textarea.
- **Marker verbs** (bold, headings, links…) are *designed into* the
  contract as the existing `ComposeFormat` transforms — a visual Cmd-B is
  `ComposeFormat.apply(.bold, …)` at the block-map-translated range. The
  spike ships paragraph text only; marker verbs are the second node-type
  card and add no new contract surface.
- **Undo** — spike limitation, owned: the DOM keeps its own undo stack and
  the buffer splices do not yet register on a shared one. The contract
  requires ops to be values *so that* a shared undo stack can replay them
  later; that integration is a follow-up.

### The block map

`ComposeBlockMap.compute(source:frontmatterStripped:)` splits the buffer
into block records by line shape — the same prefixes the highlighter
paints:

| Source shape | Kind | Rendered as | Editable? |
|---|---|---|---|
| doc-start `---`/`+++` … closing fence | `frontmatter` | stripped (policy ≠ none) or passthrough | no |
| `#{1,6} ` line | `heading` | one `hN` | no (spike) |
| maximal run of plain non-blank lines | `paragraph` | one `p` (or soft-break joined) | **yes iff single line and marker-free** |
| maximal run of list-marker lines (`- `/`* `/`+ `/`N. `/`N) `) | `list` | one `ul`/`ol` | no (spike) |
| maximal run of `>` lines | `quote` | one `blockquote` | no (spike) |
| fenced ``` run | `fence` | one `pre` | no |
| indented (tab/4-space) run | `code` | one `pre><code` | no |
| `---`/`***`/`===` line | `rule`/`setext` | `hr` / joins heading above | no |
| anything else | `opaque` | whatever Oliver emits | no |

**Editable-paragraph predicate** (all must hold): the block is exactly one
line; the line contains none of `` * _ ` ~ [ ] < > & \ { `` (any inline
marker possibility); the render options are text-preserving (smartypants,
wikilinks, and every extension that rewrites characters or block structure
are off — the defaults). This is deliberately over-strict: a paragraph
with an asterisk is simply not visual-editable yet.

**Alignment is verified, not assumed.** After Oliver renders, the host
counts the DOM's block-level children and compares against the map's
rendered-block count (frontmatter policy shifts the count; the map knows).
On any mismatch the visual surface shows the plain preview and a one-line
notice instead of editing. Misclassified shapes (setext headings, loose
lists) degrade here — visible, honest, never corrupting.

## The spike surface

A **Visual** toolbar toggle (Markdown buffers only) switches the preview
pane into visual mode:

- `ComposeVisualDocument.html(fragment:themeCSS:)` — the #230 document
  assembly plus the visual script: `data-block` numbering, per-block
  `contenteditable="plaintext-only"` for the editable index set, the
  `beforeinput` → message bridge, Enter interception, and
  caret/scroll-restore entry points.
- `ComposeVisualEditorView` + coordinator — hosts the WKWebView
  (non-persistent store, single-load navigation policy reused from
  `ComposePreviewSandbox`), receives the message-handler events, derives
  ops, splices the buffer.
- **Reconcile policy** — the visual pane does not live-reload per
  keystroke. It re-renders through Oliver after 1.5 s of edit silence or
  on blur, then restores the caret (from the last op's result offset,
  re-mapped through the fresh block map) and scroll position. Between
  reconciles the DOM's own state is provisional; the buffer is truth, so
  a reconcile discards exactly the edits that failed to map.
- Save, dirty state, status bar, find bar, and the textarea pane are
  unchanged — they all read the same buffer.

## Boundaries & fallbacks

- Cooklang/Textile buffers: no visual toggle (Markdown spike only).
- Render options that transform text (smartypants, wikilinks, …): visual
  mode stays available but with an empty editable set (read-only surface)
  until the options are back to text-preserving.
- Frontmatter present + policy `none`: editable set empty (the passthrough
  render shape is not stable to map).
- Any message the host cannot map: no-op on the buffer; next reconcile
  snaps the DOM back to truth.
- The visual pane never navigates (same sandbox as #230) and never gains
  network/file access (`loadHTMLString`, `baseURL: nil`).

## Follow-ups (not in this spike)

1. Marker verbs in visual mode (Cmd-B/I/K) via `ComposeFormat` at mapped
   ranges — second node-type card.
2. Headings and lists as editable blocks (prefix-aware text ranges).
3. Visual paragraph splitting (Enter) — needs a block-level op kind
   (`splitBlock`), contract extension.
4. Shared undo stack replaying ops across both surfaces.
5. boris-editor upstream: the same op contract expressed over its
   SourcePane (filed as an issue draft there, never a PR to boris).

## Test posture

- `ComposeBlockMapTests` — classification, editable predicate, frontmatter
  policy alignment, alignment-failure detection.
- `ComposeMarkupOpTests` — event → op derivation (insert, replace,
  surrogate-pair deletes, unmappables), application + caret results.
- `ComposeVisualDocumentTests` — document assembly: script present,
  `</style>` guard inherited, editable gating by index set.
- `ComposeVisualEditorE2ETests` — one real-WKWebView round trip (same
  pattern as #230's tests): synthetic `beforeinput` on an editable block
  → message → op → buffer contains the edit.

# zdraw update assessment

Reviewed 2026-09-10. Updated `vendor/zdraw` from `40912b0` to
`4bbcc5f` by fetching origin and fast-forwarding to `origin/main`.

Implementation follow-up: the first adoption step now uses shared layout and
selection helpers in both model pickers, with capability-gated list/help drawing
and legacy fallback. Fifteen reviewed visual baselines and PTY checks are
documented in [the picker test guide](../tests/fixtures/picker/README.md).
The assessment below records the original investigation and recommendations.

The strongest opportunities are shared UI components and better visual tests.
There is no demonstrated performance improvement from this update alone: the
four commits add optional Zsh libraries, examples, documentation and tests; the
C module and its build integration are unchanged. zcoder does not yet load the
new libraries.

## Recommended adoption order

| Priority | Feature | Concrete use in zcoder | Expected benefit |
| --- | --- | --- | --- |
| 1 | Portable visual fixtures | Capture representative modal, transcript, prompt and narrow-screen states | Review changes to cells, colors and attributes with readable HTML diffs |
| 2 | Pure layout and selection helpers | Modal centering, model-picker scrolling, responsive panel rectangles | Share validation and boundary handling while retaining zcoder's event loop |
| 3 | Panels, lists and help rows | Pilot the model picker, then other small overlays | Consistent focus, empty states, borders and shortcut clipping |
| 4 | Semantic documents | Bounded help and inspector detail views | Wrapped headings, bullets and code; reading position survives width changes |
| 5 | Inputs, forms and tables | Search fields, future host/settings dialogs, MCP status inspection | Reusable selection, validation and aligned data columns |

Start with visual baselines and one model-picker integration. That gives us a
small, observable migration before touching the main transcript or prompt.

## Where the new APIs fit

### Visual regression fixtures

[`zdraw-fixture`](../vendor/zdraw/docs/visual-regression.md) serializes retained
cells to JSON with normalized colors and named attributes. Its comparator can
produce a standalone HTML difference report. This complements our existing
[`tests/drawing.zsh`](../tests/drawing.zsh) cell-equivalence checks and PTY
interaction tests: baseline review would show an accidental border, focus-color
or clipping change across an entire fixture.

Capture fixed, deterministic windows at selected sizes and color profiles.
Normalize timestamps and other changing application content before rendering.
The limit is 16,384 cells per capture. These are logical cell fixtures, not font
screenshots; Unicode readback and platform differences still need review.
The Python comparator belongs in development tests and adds no agent runtime
dependency.

### Layout, selection and small widgets

[`zdraw-layout-center`, `split` and `inset`](../vendor/zdraw/lib/ui/layout.zsh)
are pure Zsh and accept caller-owned output state. They can replace geometry
calculations in [`ui_modal_run`](../lib/overlays.zsh) and eventually
[`ui_setup_windows`](../lib/ui.zsh). Fixed tracks that cannot fit return status
2; zcoder must still decide when to hide its sidebar or use a compact view.

[`zdraw-list-update`](../vendor/zdraw/lib/ui/selection.zsh) handles selection,
page movement and viewport clamping, including empty or shrinking lists. It
overlaps `_ui_modal_navigate` and `_ui_modal_list_draw`. Keep selected model or
session identity in application state and map it to an index after refreshing
the list; the helper's association contains only `selected` and `first`.

Panels and lists could simplify drawing in the shared modal implementation.
The renderer has shared normal/selected styles, whereas our modal supports
per-item attributes and a separate current-item marker. Preserve those meanings
explicitly; a blanket replacement would lose information. `zdraw-help` is a
particularly useful footer component because it fits complete shortcut/action
pairs instead of cutting text midway through a shortcut.

### Semantic documents

[`zdraw-document`](../vendor/zdraw/docs/semantic-documents.md) provides stable
block IDs, source-byte ranges, heading navigation and anchored reflow. A help
reader or bounded detail pane is a good fit. zcoder's generic modal viewer
currently displays an array of lines without this semantic navigation.

The current API is unsuitable as a direct replacement for the transcript:

- Limits are 128 blocks, 32,767 bytes per block, 65,536 source bytes overall and
  4,096 compiled rows. A transcript can exceed these limits.
- Changed source requires a new document compilation. Our transcript renderer
  already tracks the earliest changed event and reuses earlier rendered rows.
- It supplies neither inline styled spans nor syntax highlighting. We already
  render styled syntax/diffs and retain independently foldable reasoning and
  tool-event groups.
- Every draw validates every compiled row, including offscreen rows. That makes
  validation work grow with document size even for an unchanged viewport.

For future transcript work, the useful design is an anchor consisting of event
ID plus source offset. It could improve reading-position retention through
resize without adopting the bounded document container. An upstream incremental
block-update API and retained validated drawing data would make a larger
migration more attractive.

### Inputs, forms and presentation components

[`zdraw-input`](../vendor/zdraw/docs/inputs-and-forms.md) offers selection and
editing at native text-unit boundaries. Our editor moves/deletes by Zsh character
offsets, so keeping a base character with its combining marks is a useful
correctness improvement to investigate independently.

The widget is single-line, rejects tabs/newlines and supports at most 32,767
bytes. zcoder has multiline prompts, vertical cursor movement, history and
large-paste handling, including 100,000-character benchmark workloads. Retain
that editor; use the widget for bounded search/settings fields. Its byte offsets
also require an explicit conversion if bridged to `INPUT_POS` character offsets.

Forms support up to 16 fields and built-in unsigned integer/length validation.
They do not validate URLs or implement password masking, so a host dialog still
needs application validation and secret fields need a different solution.
Native paste streaming was already available at the old pin, and zcoder already
uses it in [`terminal_read_event`](../lib/terminal.zsh). The new transactional
paste helper primarily benefits the new fields.

Tables could make an MCP inspector easier to scan with separate name/status/tool
count columns. Stable row identity, sorting and filtering remain application
responsibilities. Badges/meters could improve activity and context displays;
meter inputs are limited to 32,767, so token counts must be scaled to a bounded
ratio before drawing.

## Performance and integration constraints

[`ui_draw_row`](../lib/drawing.zsh) already caches resolved styles and uses native
`spansclip` batching. [`_ui_paint_chat`](../lib/ui.zsh) caches rendered events and
draws the visible rows. Preserve those paths until an alternative is measured
with long transcripts, streaming updates and real PTY redraws. The toolkit list
also validates offscreen items on each draw, and the utility resolver reparses
styles; fewer application lines do not establish lower latency.

Two performance candidates already existed before these four commits:

- Native `prepare`/`draw` could avoid repeated span decoding for unchanged rows.
  Use a bounded visible/recent-row cache, with invalidation on content, style,
  locale and session changes and explicit `unprepare` cleanup.
- `resizewin`/`movewin` could preserve ordinary windows when prompt height changes;
  `ui_setup_windows` currently destroys and recreates them. Measure resize and
  multiline-edit latency before adopting this path.

The toolkit renderers call `zdraw` directly. Our loader deliberately supports
stock `zsh/curses`, preloaded modules and host-specific ABI stamps, including
machines receiving rsynced binaries. Gate widget rendering on the required
zdraw capabilities and retain the stock rendering path. Pure layout/selection
helpers can be shared by both backends.

Load only selected libraries from the terminal UI path. Keep toolkit state local
to the appropriate view using its documented dynamic-scope protocol. zcoder
continues to own refresh scheduling, input, paste draining, command approval and
terminal cleanup. The root `make compile` currently compiles only `lib/*.zsh`;
any future vendor-library compilation should target the files actually loaded.

## Verification and scope

- `make compile`: passed.
- `make test`: passed, 2,546 assertions.
- In `vendor/zdraw`, `PYTHONPATH=tests python3 -m unittest test_ui test_input
  test_document test_visual test_compositions -v`: all 17 tests passed, including
  real PTY interaction, resize and visual baselines, using the existing built
  shell/module pair. No native source changed in this update.
- The host shell is Zsh 5.9.2. These runs do not establish Zsh 5.8 runtime
  compatibility; that remains a separate validation before integrating helpers.

This assessment changes the local submodule checkout and adds this report.
Application behavior has not been migrated. Existing documentation edits were
preserved. No commit, push or farm deployment was performed.

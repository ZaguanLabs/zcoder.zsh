# zdraw 0.1.0 review

Reviewed on 2026-09-17 against the [selection request](zdraw-text-selection-feature-request.md).
Updated `vendor/zdraw` from `c868776` to tag `v0.1.0`, commit `64263c7`.
This is zdraw's first versioned release; the selection API remains experimental.

Follow-up: [v0.1.1 verification](zdraw-0.1.1-review.md) covers the fixes for the
outside-origin drag and native Zsh 5.8 issues reported here.

## What the release provides

The optional `lib/zdraw-text-selection.zsh` companion supplies reading-order
selection within explicit content geometry. Highlight spans and extracted bytes
share caller-supplied text mappings, so neighboring panes and screen padding
do not enter the result. It handles reverse drags, outside releases, UTF-8
boundaries, soft wraps, real newlines, styles, cancellation, and revision changes.
The application retains its event loop, rendering, and clipboard transport.

The native `mouse delay` argument now accepts valid integers, allowing
`zdraw mouse delay 0 motion` to request responsive press/drag/release events.
The release also contains a separate raster experiment and a held-key example;
neither is required for chat selection.

The two-pane demo can be run from the zcoder checkout after building zdraw:

```sh
vendor/zdraw/.build/zsh/Src/zsh -df vendor/zdraw/examples/text-selection.zsh --mouse
```

Ordinary left drag selects; `c` displays the extracted text; Escape clears;
`q` exits. Add `--mono` for monochrome. The demo does not write the clipboard.
Kitty's Shift-drag and Ctrl+Shift+C continue to operate on Kitty's own selection.

## Integration work in zcoder

Updating the dependency does not enable chat selection. The existing renderer
has visible rows and style fragments, but also mixes in role headings, gutters,
fold controls, and padding. It needs a canonical copy-text projection with
byte offsets and explicit soft-wrap versus real-newline information. Raw
Markdown and a concatenation of padded screen rows cannot serve as that mapping.
The component accepts contiguous text per mapped row; arbitrary folds, tab
expansion and omitted markup must be resolved before initialization.

`terminal_read_event` currently flattens mouse events into the legacy input
representation. Integration should route structured events to the selection
owner before existing pane controls, observe `consumed`, and manage mouse
motion/click delay for the owning session. The renderer must draw returned spans
using the same Unicode policy as its text mappings.

During selection, retain a stable visible projection while receiving model
output separately, or explicitly cancel when its revision changes. Scroll,
resize, fold changes, and modal entry need equivalent lifecycle handling.
Copying requires an explicit application action and a clipboard adapter.

## Findings for upstream

1. **Outside-origin drags with repeated button state.** The documented event
   contract allows motion to repeat `PRESSED1`. An outside press followed by
   such a motion inside the pane starts a selection. The helper remembers an
   active inside drag, but does not remember a press that began outside.
   This contradicts the requested outside-origin behavior for this event form.
   It is a synthetic event-contract reproduction, not an observed Kitty bug;
   the ordinary encoded SGR path is covered separately by upstream PTY tests.
2. **Zsh 5.8 native compatibility.** The unchanged build-integration patch does not apply
   to pristine Zsh 5.8: its configure context differs and `mod_watch.yo` is absent.
   A temporary review copy adapts only these patch contexts, and configures the
   old shell with the compiler compatibility flags already used in earlier
   minimum-version reviews. Compilation then fails because native calls to
   `zlinklist2array(list, 1)` use the newer two-argument signature; Zsh 5.8 accepts
   one argument. The prior pinned zdraw also has such calls, so this is not a new
   selection regression. The minimum-version native check remains blocked;
   syntax checks alone would not establish working support. zcoder's normal
   private runtime uses matching Zsh 5.9.2 and builds successfully.

Reproduce the first finding with the matching built shell, from `vendor/zdraw`:

```zsh
module_path=("$PWD/.build/modules")
zmodload zdraw
source lib/zdraw-text-selection.zsh
typeset -A zdraw_text_selection zdraw_selection_event
zdraw-text-selection-init abc r 2 2 3 4 native 0 0 0 '' abc
zdraw_selection_event=(type mouse x 0 y 2 buttons PRESSED1 modifiers '')
zdraw-text-selection-event r
zdraw_selection_event=(type mouse x 3 y 2 buttons PRESSED1 modifiers '')
zdraw-text-selection-event r
print -r -- "$zdraw_text_selection[selected]" # 1; expected 0
```

## Local measurements

Ran `benchmarks/text-selection.zsh` with matching Zsh 5.9.2 in C.UTF-8.
Five batches of 1,000 motion events; span batches generate all 24 visible rows.
Build/test work was also running, so these are indicative computation timings,
not isolated latency guarantees or a comparison with the previous release.

| Source | Initialization | Median event | Median spans, 24 rows |
| --- | ---: | ---: | ---: |
| 100 lines / 7,100 bytes | 56.6 ms | 55.6 µs | 19.4 ms |
| 10,000 lines / 710,000 bytes | 407.5 ms | 31.9 µs | 11.7 ms |

Do not interpret the faster second run as a benefit from larger documents.
The useful distinction is cheap retained event processing versus more expensive
initialization and highlight generation. Initialize on layout/revision changes,
retain the mapping during a drag, and redraw affected rows. Rebuilding the full
projection on each streaming chunk would risk visible pauses.

## Validation

- `make native`: passed; rebuilt the private Zsh 5.9.2 runtime with this release.
- `make compile`: passed.
- zcoder `make test`: all **3,741 assertions passed**, 86.946 seconds, no omitted
  integration groups. Document Escape closure measured 0.213–0.215 seconds.
- Upstream `make test`: all **174 tests passed**, 351.134 seconds, including all
  five new selection tests for ranges/events, native styles, and PTY interaction
  with enabled, disabled, and monochrome selection.
- Separate native Zsh 5.8 build: failed as described above; no minimum-version
  runtime pass is claimed.

Upstream also includes recorded real Kitty 0.44.0 observations and screenshots;
this review's terminal interaction checks use PTYs, not physical pointer input.

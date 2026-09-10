# Model picker visual baselines

Run `make test-visual` from the repository root. It requires a locally built,
ABI-matching zdraw module with wide text/drawing and window snapshots. Build it
using the existing `ZSH_BUILD_ROOT=... make curses` workflow. `make test` also
runs the picker checks, but permits stock-only machines to skip visual captures.
Python is not needed for capture or baseline comparison.

The PTY tests exercise the actual shared picker in stock curses and zdraw,
covering End/Home navigation, terminal resize, accepting a model whose name
contains spaces, cancelling an empty list, recovery from a partial native draw
failure, unusual model names, and preservation of the draft and cursor.

Fifteen JSON fixtures cover the initial selection, scrolled selection, narrow
layout after resize, empty list, and legacy rendering after a simulated partial
widget failure. Each is captured in 256-color, monochrome and basic-color mode
using `xterm-256color`. The application palette is reused by the widgets.
Only the modal window is captured, avoiding changing timestamps and machine
names in the underlying application frame.

Capture files are retained in `.build/picker-visuals/`. Comparisons fail on
changes to dimensions, cursor position, cell text, colors or attributes. Inspect
a failure with the command printed by the test, for example:

```sh
python3 vendor/zdraw/scripts/visual_diff.py \
  tests/fixtures/picker/auto-auto-choose-1-44.json \
  .build/picker-visuals/auto-auto-choose-1-44.json \
  --html .build/picker-visuals/diff.html
```

After an intentional rendering change, regenerate and review the differences:

```sh
ZCODER_UPDATE_VISUALS=1 make test-visual
git diff -- tests/fixtures/picker
```

Normal tests never update baselines. These fixtures describe retained cells,
not font rendering: wide-character continuation columns repeat the glyph in
the readback format. Locale and curses differences can be visible; investigate
them before accepting a new baseline. Stock-curses behavior remains covered by
the PTY interaction checks and the existing drawing/overlay tests.

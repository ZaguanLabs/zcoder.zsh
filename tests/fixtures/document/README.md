# Help/document reader fixtures

`make test-visual` exercises the picker and the read-only document viewer.
The viewer tests run against stock curses and zdraw in color and monochrome.
Their eight baselines capture the narrow reader at its first heading, actual
keyboard help on a narrow terminal, the grouped Tools and sessions entries at
normal width, and legacy repaint after a simulated partial native draw failure.

The PTY checks verify next-heading navigation, scrolling into a paragraph,
resize retention of the source block, and native reflow retention of the
original source byte. They also cover Home, closing help without changing the
transcript, an Escape close latency below 800 ms, preservation of the input
draft/cursor, and readable fallback when
the source exceeds the native document's per-block byte limit.

Actual captures remain in `.build/document-visuals/`. Normal tests compare the
portable JSON exactly and never update baselines. For an intentional change:

```sh
ZCODER_UPDATE_VISUALS=1 make test-visual
git diff -- tests/fixtures/document
```

Use `vendor/zdraw/scripts/visual_diff.py` with an expected and actual JSON file
and `--html PATH` to inspect a mismatch. As with the
[picker fixtures](../picker/README.md), these are retained-cell comparisons,
not font screenshots. Python is optional for visual reports; it is not used by
the application or by baseline comparison.

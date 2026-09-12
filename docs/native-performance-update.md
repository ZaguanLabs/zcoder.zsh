# Native performance update, 2026-09-12

Updated the pinned dependencies without changing zcoder's adapters:

- zdraw: `9c599d8` → `9cf1a2f`
- zmdown: `8bb1390` → `312b955`

Both updates preserve the APIs and width/style policies used here. The new
private runtime is selected by the normal launcher after `make`. Already
running processes retain their previous runtime until restarted.

## Changes relevant to zcoder

zmdown accelerates ASCII handling, Unicode property lookup, structured output
allocation, and table fitting. Explicit-width association output also avoids
unnecessary terminal queries. zcoder already uses that interface.

zdraw accelerates text measurement and validation, repeated styled cells,
window lookup, and row/fill operations. The companion style resolver is also
faster. Canvas and chart improvements are useful upstream but are not current
zcoder workloads. No new feature flag is needed to use these optimizations.

See the upstream [zdraw measurements](../vendor/zdraw/benchmarks/performance-2026-09-12.md)
and [zmdown profiling report](../vendor/zmdown/docs/performance.md).

## Application measurements

The comparison used the previous and replacement private Zsh 5.9.2 runtimes,
the same application sources, a drained 30×100 PTY, `xterm-256color`, UTF-8,
and CPU affinity 2 on this workstation. Seven fresh-process trials alternated
version order. Each operation had three warmups and a batch of ten calls
(40 for redraw). Values below are medians of batch averages in milliseconds.

Fixtures contained 24 styled prose paragraphs, 24 mixed Unicode paragraphs,
48 fenced Zsh code lines, or a 36-row table. Layout rebuilt the complete
transcript at 98 columns; redraw reused its layout and painted the visible
viewport. Span generation used zmdown's `wcwidth-sum` / `first-base` policy at
96 content columns. Initialization, snapshot export, and cleanup were untimed.

| Workload | Span generation, before → after | Complete layout, before → after | Cached redraw, before → after |
| --- | ---: | ---: | ---: |
| Prose | 0.711 → 0.215 | 16.021 → 14.797 | 2.852 → 2.736 |
| Mixed Unicode | 0.527 → 0.226 | 10.495 → 9.901 | 2.770 → 2.701 |
| Fenced code | 0.723 → 0.163 | 25.035 → 23.864 | 4.511 → 4.371 |
| Table | 0.661 → 0.308 | 12.420 → 11.751 | 3.494 → 3.381 |

Span generation was 2.15–4.43× faster. Complete layout took about 5–8% less
time; cached redraw medians were about 3–4% lower. Redraw distributions partly
overlap, so those small differences should not be treated as a guarantee.
The difference between module and complete-layout gains suggests that the
remaining application pipeline, including row adaptation and syntax
highlighting, limits the overall improvement.

All exported layout arrays, styles, span offsets, and retained viewport-cell
snapshots were identical across both versions and all seven trials. There were
no Markdown fallbacks. This measures module/application work, not terminal
emulator painting, network latency, or model generation.

An initial CPU-0 run showed a large timing shift halfway through both versions.
Its apparent 2× application-level speedup was discarded; the stable repeat
above supersedes it. The temporary drivers and samples are retained locally
under `/tmp/zcoder-native-bench.*` and
`/tmp/zcoder-native-perf-20260912-repeat/`.

## Validation

Both the private runtime and the installed-shell development modules were
rebuilt from the updated pins. `make compile` passed. `make test` passed all
2,955 assertions with no integration groups omitted, including native Markdown
and all 23 retained-cell visual baselines. These cover Unicode fallback, real
terminal input, resize, presentation, widgets, and application behavior. No
new regression assertions were added for this dependency update.

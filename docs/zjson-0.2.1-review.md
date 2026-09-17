# zjson 0.2.1 verification

Tested on 2026-09-17. Updated `vendor/zjson` from `05c6c71` (0.2.0) to
`acf233b21cfa4ae0844639486f7724058c7fb3e3` (0.2.1). The application adaptations
from the [0.2.0 review](zjson-0.2.0-review.md) remain in place.

## Correctness and compatibility

- `make compile`: passed with the updated dependency.
- Upstream matrix: **14,237 checks, zero failures per run**, using actual Zsh
  5.8 and 5.9.2, each in C and C.UTF-8. This includes nested parser restoration
  and the new error-unwinding cases.
- All application and dependency libraries compile with actual Zsh 5.8.
- The 72 application upgrade regressions pass on Zsh 5.8 in each locale.
- `make test`: ran all 3,741 assertions with no integration groups omitted;
  **one assertion failed**, for terminal document navigation/visual checks.
  All other assertions passed.

The document test failed its Escape latency limit: closing help took 4.23 s in
an isolated 0.2.1 run, exceeding the 0.8 s threshold. A control run with 0.2.0
also failed the same check, at 6.52 s. This is reproducible on both versions in
the current environment; its underlying cause was not resolved in this update.
The dependency was restored to 0.2.1 and recompiled after the control run.

### Escape timing follow-up

Profiling located the delay in the test fixture's status-file writes, rather
than JSON parsing or application rendering. Writes under `.build` took about
453 ms each through `mapfile`, compared with 0.025 ms in `/tmp`. The fixture's
draw wrapper averaged about four seconds; the actual document renderer took
about 3 ms and the main-screen redraw about 5 ms.

The document test now uses a private temporary directory for coordination,
retains visual captures under `.build/document-visuals`, and measures closure
of help before opening the next document. The 0.8 s threshold is unchanged.
The corrected standalone test passed for stock curses and zdraw with all eight
visual baselines. As a negative control, setting `ESCDELAY=1200` still failed
the check at 1.31 s, confirming that a real input delay remains detectable.
The subsequent full `make test` run passed all 3,741 assertions, with Escape
closure at 0.213–0.216 s across the three terminal configurations. `make compile`
and Zsh 5.8 syntax checks for both changed test files also passed.

### Encoder limitation

The encoder issue remains: `zjson_encode_value 42 '{'` returns success and `42`.
The release does not modify `lib/encode.zsh`; container root types still need
an explicit check when using that API.

## Performance

Used `tests/benchmark_json.zsh` on Linux x86_64, Zsh 5.9.2, C.UTF-8, after
the test processes finished. Each comparison uses two warmup batches and seven
measured batches; repeated the comparison in reverse version order. The table
shows ranges of the two run medians, in milliseconds per operation.

| Workload | 0.2.0 | 0.2.1 |
| --- | ---: | ---: |
| Quote 16,384 `é` characters | 4.494–4.603 | 3.812–3.813 |
| Validate the same Unicode string | 7.261–7.300 | 6.558–6.725 |
| Object callbacks, 500 fields | 341.875–351.898 | 91.500–92.189 |
| Object decode, 500 fields | 67.172–67.936 | 67.088–68.062 |
| Ollama stream chunk | 0.502–0.511 | 0.531–0.551 |
| Ollama tool response | 1.463–1.549 | 1.565–1.708 |

Unicode quoting improves about 15–17%, validation about 7–10%, and callbacks
about 3.7–3.8 times. The targeted regressions are substantially reduced.
Callbacks still cost about 36% more than direct object decoding in this case.
Small Ollama parsing timings were slightly higher and variable; this run does
not establish a general application speedup. No hot-path codec rewrite is
included.

For a repeat comparison, archive commit `05c6c71` into a temporary directory
and pass that directory through `ZJSON_BENCH_ROOT`, as documented in the prior
review. These are local microbenchmarks, excluding model, network, and terminal
latency.

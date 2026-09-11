# Development

zcoder targets Zsh 5.8 and newer. Keep application logic Zsh-first and preserve
the separation between Ollama, tool dispatch, persistence, remote transport,
and curses.

## Project checks

Run the complete required suite before handing off changes:

```sh
make test
```

`make test` first parses the entry points, libraries, tests, and fixtures with `zsh -n`,
then runs the shell-level suite. The suite covers:

- strict native JSON grammar, Unicode controls, and encoding
- both supported MCP protocol generations
- paginated MCP discovery and nested tool calls
- reasoning and tool history
- serialized per-call dispatch and transport recovery
- context accounting and compaction
- path and symlink confinement, including inherited ripgrep configuration
- file reads, writes, search, and patch fallback
- loop detection and completion recovery
- sessions, Skills, and project instructions
- interrupted session publication, immutable record reuse, reader leases, and generation collection
- stale session writers, unavailable-skill reloads, and session/turn-scoped remote cancellation
- Ollama, delegate, and remote cancellation
- command approval, denial, and safety guards
- authenticated remote events and approvals
- partial ACP/MCP frames, top-level response IDs, and request-bound ACP permissions
- same-host relay framing, discovery, delivery, and origin isolation
- input handling and curses rendering
- queued-input ordering, stable IDs, interrupted consumption recovery, and HTTP/ACP admission

Run syntax checks alone with:

```sh
make check
```

Run `make compile` after changes and after a Git push. It also runs the syntax
checks, then compiles the libraries with the installed Zsh. These commands do
not substitute for executing the suite on Zsh 5.8 when checking that minimum
version specifically. Run the suite using an actual Zsh 5.8 runtime to establish
that compatibility; source parsing and wordcode compilation on the development
host establish only compatibility with that host's installed Zsh. Rebuild `.zwc`
files with the destination host's Zsh instead of assuming generated wordcode is
portable between versions.

The TUI integration checks run real local and remote entrypoints in PTYs against
native TCP fixtures. They cover startup cancellation, draft recovery, streaming,
inspectors, terminal re-entry, persistence, and shutdown cleanup alongside the
individual process, MCP, discovery, and approval tests. A thousand-entry
transcript check counts layout and curses operations: idle refreshes and draft
editing must not re-render history, while stream updates lay out only the
changed entry. These are deterministic regression checks, not terminal-emulator
latency benchmarks or measurements of live Ollama inference.

The [overlapping-operation audit](test-gap-audit.md) records two reproduced
test gaps, the regression cases added for them, and remaining limitations.
The [TUI review](tui-review.md) assesses event-loop and overlay complexity and
records the stock-curses modal paste regression and its coverage.

`tests/context_accounting.zsh` checks retained reasoning and Skill content,
interrupted stream previews, missing usage reports, and attribution of runtime,
routing, and verifier guidance. The agent-loop tests also cover a tool response
with measured usage followed by a final response without a prompt count.

`tests/input_queue.zsh` exercises the real agent loop with controlled responses:
all tool results must precede steering, and follow-ups must wait for completion.
Its PTY fixture checks Enter, Ctrl+G, Unicode/multiline paste, draft preservation,
and cancellation using the actual editor and queue.

## Building the native dependencies

The normal fresh-checkout path is `make` (or `make setup`). See
[setup and build requirements](getting-started.md#enhanced-curses-module).
It builds an isolated Zsh 5.9.2 runtime with both pinned modules, installs only
that shell and its modules under `.build/native/`, verifies their contracts,
and atomically publishes a data pointer to the completed build. The launcher
checks the host and checkout path before selecting it. Running processes retain
their immutable build prefix when a replacement is published.

`make compile`, `make check` and `make test` do not invoke native setup. Existing
system-shell builds in `vendor/*/.build` remain separate from private setup.
Build fingerprints include dependency commits, setup script, source checksum,
host/path and compiler flags. Previous builds are retained so rebuilding does
not remove files used by running processes. Removing `.build/native/` disables
the private runtime; stop processes using it before removing their build files.

### Advanced: build for the installed shell


`vendor/zdraw` is a pinned Git submodule using
`https://github.com/ZaguanLabs/zdraw`. Initialize it over public HTTPS:

```sh
git submodule update --init --recursive
ZSH_BUILD_ROOT=/path/to/matching/configured/zsh make curses
make test
make compile
```

For an existing checkout, synchronize the local submodule URL after updating:

```sh
git submodule sync --recursive
git submodule update --init --recursive
```

The dependency can now configure and build an extracted public Zsh release in
isolation; its tested baseline is 5.9.2. See `vendor/zdraw/README.md` for that
standalone workflow. Our `make curses` integration still requires a configured,
built source tree matching the installed shell, because it enables the module
for ordinary zcoder launches. `make curses` checks the
source-tree shell's version, patch level, and platform against the running Zsh,
builds in `vendor/zdraw/.build`, checks that the module loads in a fresh shell,
and writes a local version/platform/host stamp. It never installs a system module.
The source tree and its C toolchain/development dependencies are build-time
requirements; ordinary `make compile` still only compiles Zsh libraries.

Fresh application processes select the bundle only with a matching stamp and
available binary. A load failure falls back to the normal module search path.
An already loaded module is retained. The adapter dispatches to `zdraw`
or stock `zcurses` and reads the selected module's features and color limits.
`ZCODER_CURSES=stock` bypasses the bundle; `/terminal` reports selection and
native versus fallback resize queries.
The stamp guards against common mismatches, including copying the build to a
different farm host; it is not proof of ABI compatibility for arbitrary builds
with different configuration flags. Supply a source build matching the installed
shell. The experimental C module has not been validated against Zsh 5.8;
the automatic setup instead runs both modules in its own Zsh 5.9.2.

After upgrading from `vendor/zcurses`, run `make -C vendor/zdraw clean`
once before rebuilding to discard the old module build cache.

Rebuild after changing the pinned submodule revision or upgrading the local
shell. When changing source trees or build configuration, run
`make -C vendor/zdraw clean` first; this preserves downloaded sources while
removing the working build and staged module. Farm headless
processes need no module build; the NAS may receive the source via rsync and
continues to run headlessly without a compiler or Make.

`make test` automatically includes the production module loader in the resize
PTY tests when a matching local build is present. It also runs stock-module
resize tests, verifies native polling launches no `stty` subprocesses, and tests
missing/mismatched builds and failed loads independently of curses. To test an
external development build as well, set `ZCODER_TEST_CURSES_PATH` to its modules
directory. The dependency's own broader module checks use a Python 3 PTY driver:

```sh
ZSH_BUILD_ROOT=/path/to/matching/configured/zsh make -C vendor/zdraw test
```

The module adds `geometry`, custom borders, runtime `colorinfo`,
opt-in RGB colors and styled-span batching, with discovery through
the read-only `zdraw_features` array. Its build also requires Autoconf,
Autoheader, M4 and Patch for optional curses function checks. Its own RGB tests
use `tic` to compile private terminfo fixtures. These are development tools,
not additional runtime requirements for zcoder.
zcoder checks the discovery parameter with `zmodload -F -e` on UI entry; an
advertised geometry feature selects native polling even if its first query
fails. A known feature set without geometry selects stty without probing the
command. Missing/disabled discovery retains the legacy one-time probe, including
compatibility with the original geometry-only fork. `/terminal` lists compiled
features separately from negotiated terminal state and active drawing modes.
General Unicode clipping remains outside the drawing adapter. The application
PTY tests compare batched/fallback retained cells and exercise combining-mark
rejection, indexed and monochrome palettes, and stock/bundled modules.

`make test-visual` runs the picker and help-reader PTY tests and compares retained
cell fixtures. It requires a matching zdraw build. The regular `make test` runs
the same interaction checks but permits stock-only hosts to skip captures.
See the [picker baseline guide](../tests/fixtures/picker/README.md) and
[document baseline guide](../tests/fixtures/document/README.md) for reviewing
differences and explicitly regenerating fixtures. Python is only needed for
optional HTML comparison reports.

When both `structured_events` and `norefresh_events` are advertised, input uses
`event ... norefresh` so reads cannot present unfinished drawing. Feature
selection is cached per UI entry. Character, key, resize and supported mouse
records feed the existing paste and terminal-reply filter; frame presentation
stays with `terminal_refresh`. Missing capabilities use legacy `input`. Only
status 2 (unsupported before consuming input) disables the new path and retries
through legacy input; timeouts and other failures never trigger a second read.
`/terminal` reports the active input presentation mode.

Session-scoped prepared rows (`prepare`/`draw`) and headless byte/column
hit-testing (`textpos`) remain available for experiments. Prepared rows need
measurement against our existing transcript cache before adoption, and
`textpos` returns byte offsets rather than the editor's character indices.

## Building optional Markdown support

`make` includes Markdown support automatically. For the advanced installed-shell
path, `vendor/zmdown` is pinned at `8bb1390`; zdraw is pinned at `9c599d8`.
Build both modules against the configured source tree matching that shell:

```sh
git submodule update --init --recursive
ZSH_BUILD_ROOT=/path/to/matching/configured/zsh make curses markdown
make compile
make test
```

With `ZSH_BUILD_ROOT` set, `make markdown` builds only zmdown and writes the same local ABI/host stamp used
by the curses loader. Neither module is installed system-wide. Normal startup,
headless operation and `make compile` require no C toolchain. Rebuild after a
dependency or shell update; copied farm binaries are not enabled on other hosts.
An already loaded zmdown is retained and its output contract is checked.

Native Markdown requires both modules, UTF-8 and zdraw's grapheme-safe text
policy. zmdown supplies `wcwidth-sum` / `first-base` structured rows; the app
preflights their complete text and cell counts before publishing a message.
zdraw then clips those rows with `unicode-17.0.0-egc-wcwidth-sum-attach-zero`.
Syntax colors remain application-owned. Resize and streaming updates regenerate
rows from the original Markdown; cached rows retain their drawing policy.

`tests/markdown_native.zsh` always tests optional loading and capability fallback.
When both local builds are available it also runs a real PTY, comparing retained
cells across widths and checking streaming, copying, and Unicode rejection.
The existing Markdown tests continue to cover the dependency-free renderer.

## Performance measurements

Run the opt-in native microbenchmarks with:

```sh
make benchmark
```

The target runs syntax checks, then `tests/benchmark.zsh`. Each case uses three
warmups and five measured samples by default and reports elapsed milliseconds
as median/minimum/maximum, alongside Zsh, platform, and locale information.
To change the sample counts:

```sh
ZCODER_BENCHMARK_WARMUPS=3 ZCODER_BENCHMARK_SAMPLES=7 make benchmark
```

At least one warmup and three samples are required. Cases cover paste decoding,
Unicode JSON controls, fresh and cached input layout, cold and warm context
accounting, and cached transcript redraw. The redraw case mocks curses; the
benchmarks require no Ollama server or interactive terminal and measure neither
network latency nor actual terminal painting. Timing thresholds are deliberately
absent from `make test`.

Compare the same fixture, locale, Zsh version, and sample settings on a quiet
machine. The [v0.12.2 release notes](releases/v0.12.2.md) record targeted local
before/after measurements, including ranged file reads; those targeted fixtures
are separate from the reusable benchmark target. Functional assertions remain
the gate for correctness. Broaden performance checks when a change affects a
new path or a measurement exposes a regression.

Session persistence tests distinguish interruption before publication from a
committed save. They do not establish durability against power loss: generation
publication uses atomic rename and checked writes without an `fsync` guarantee.
See [session persistence](architecture.md#session-persistence) for reader and
writer coordination and [upgrade precautions](releases/v0.12.2.md#session-storage-and-upgrade-precautions)
before testing a downgrade against saved user sessions.

## Real-model evaluation

Real inference is opt-in and not part of `make test`. The evaluation target
creates isolated temporary workspaces, denies shell commands, and reports
tab-separated results for repeated reads, dependent search, edit-and-verify,
failure recovery, project-instruction compliance, implicit Skill routing,
Skill non-match precision, and conversational scenarios.

```sh
ZCODER_EVAL_MODELS='ornith-1.5:9b,laguna-xs-2.1' \
ZCODER_EVAL_REPEATS=3 \
make model-eval
```

Runs are grouped by model to amortize model-loading time. Use
`ZCODER_EVAL_SCENARIOS` for a comma-separated subset when doing a quick probe,
and `ZCODER_EVAL_OUTPUT_DIR` to retain the human transcript and JSONL model/tool
history for every run:

```sh
ZCODER_EVAL_MODELS='lfm2.5-8b-q6-128k' \
ZCODER_EVAL_SCENARIOS='conversational,independent_reads' \
ZCODER_EVAL_OUTPUT_DIR=/tmp/zcoder-eval \
ZCODER_EVAL_REPEATS=1 \
make model-eval
```

The TSV output includes elapsed time, transcript, and history paths. A model's
first scenario may include its Ollama load time; compare later scenarios for
warm performance.

Set `ZCODER_EVAL_BASELINE_PROMPT_FILE` to a complete earlier system prompt to
compare `current` and `baseline` variants. The `{{WORKSPACE}}` placeholder is
replaced with each temporary fixture path.

Model availability, quantization, sampling defaults, and Ollama configuration
remain the operator's responsibility.

## Implementation expectations

- Prefer native Zsh modules and parameter expansion for application logic.
- Use external tools when they are the capability: `rg`, `git apply`, `patch`, and approved commands.
- Keep model-exposed file operations inside `ZCODER_WORKSPACE`, including symlink resolution.
- Never bypass the `run_command` approval policy.
- Keep tool dispatch independently testable from curses and Ollama.
- Update the patch release before a Git push; change the minor release only when directed by a maintainer.

[Documentation index](README.md) · [Architecture](architecture.md) · [Project README](../README.md)

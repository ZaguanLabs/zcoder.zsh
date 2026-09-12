# Test suite audit

Audited on 2026-09-12, after the compact status-bracket fix. The baseline was
3,006 assertions. This is an inventory and a focused review of repetition,
runtime, and module ownership; it is not a line-by-line proof of every test or
a code-coverage measurement.

## Findings and changes

The assertion counter increments for every `assert_*` call, including calls
inside loops. A terminal scenario can contribute many assertions, while a
standalone native-module test reports one outer assertion despite checking
many conditions internally. Reducing that number alone is not an improvement.

The header geometry test repeated five statuses at five widths. Busy-state
normalization already has separate coverage, and the real terminal fixture
checks that successive tool phases leave the header unchanged. The geometry
matrix now compares Ready with an overlong error at 40, 99, 100, and 160 columns.
Those cases cover a narrow layout, both sides of the status-budget change, and
a wide layout. They check compact brackets, right alignment, and unchanged
identity text. This removes 51 assertions while adding explicit coverage of
the 99/100-column boundary.

The other reviewed matrices exercise materially different behavior: native
versus stock input ownership, cancellation versus completion, malformed frame
types, Unicode boundaries, or interrupted writes. They remain in place.
Assertions were not bundled into opaque booleans just to reduce the count.

`make test-fast` now omits the expensive integration groups at explicit
boundaries, after any shared mocks have been restored. `make test` still runs
the complete suite. The runner reports omitted groups, assertion totals, and
elapsed time; `--timings` adds timings and assertion counts by section.
Tests still run in their original source order and scope. This avoids turning
the selection change into an unrelated rewrite of shared fixture state.

## Coverage retained

| Area | Representative tests | Failure the checks protect against | Selection |
| --- | --- | --- | --- |
| Commands and file access | `run.zsh`, `hardening_json_tools.zsh`, `user_shell.zsh` | Unapproved execution, unsafe argument handling, paths or symlinks escaping the workspace | Fast and full |
| Sessions and concurrency | `hardening_state.zsh`, `concurrency.zsh`, `memory_accounting.zsh` | Corrupted publication, a stale writer replacing newer history, unbounded retained caches | Fast and full |
| JSON and protocols | `json_utf8.zsh`, `hardening_protocol.zsh`, `stream.zsh` | Invalid bytes or partial frames being accepted, wrong request IDs, premature streamed tool execution | Core checks in both; stream PTY in full |
| Agent behavior and input queue | `run.zsh`, `input_queue.zsh`, `context_accounting.zsh` | Wrong tool ordering, dropped steering, follow-ups consumed too early, stale context accounting | Core checks in both; live queue fixtures in full |
| Transcript and editor logic | `transcript.zsh`, `overlays.zsh`, `activity.zsh`, `focus.zsh`, `slash.zsh`, `status.zsh`, `hardening_input.zsh` | Lost drafts, wrong focus, stale transcript rows, pasted text becoming a command, header overlap | Logic checks in both; real PTYs in full |
| Module adapters | `curses.zsh`, `native_input.zsh`, `native_sync.zsh`, `terminal.zsh`, `resize.zsh`, `handoff.zsh` | Wrong capability selection, duplicate input ownership, failed presentation losing pending work, broken fallback | Logic checks in both; real PTYs in full |
| Native setup and rendering | `native_setup.zsh`, `markdown_native.zsh`, `drawing.zsh`, `presentation.zsh`, `picker.zsh`, `document.zsh` | Incompatible runtime selection, bad row adaptation, unintended repaint, widget integration regressions | Full |
| Process and network lifecycle | `process.zsh`, `tool_wait.zsh`, `mcp_connect_wait.zsh`, `remote_wait.zsh`, `remote_browse.zsh`, `models_wait.zsh`, `context_wait.zsh` | Unresponsive cancellation, leaked workers, stale discovery replacing current choices | Full |
| Actual application and remote storage | `tui_integration.zsh`, `remote_sessions.zsh` | Entrypoint wiring errors, missing API sessions, failed restart or terminal cleanup | Full |

The fast target retains inexpensive real child-process, socket, and fault
injection checks. It is a shorter development check, not a pure unit-test suite.
The full suite remains required before handoff. Visual checks still run when
the matching native modules are available; `make test-visual` requires them.

## Markdown and native module ownership

`tests/markdown.zsh` exercises zcoder's own Zsh fallback renderer, which remains
in use when native Markdown is unavailable or disabled. Its 50 assertions
therefore are not redundant tests of zmdown's parser.

The native fixture exercises the adapter from zmdown spans through zdraw to
retained terminal cells. It checks reflow, styles, original-text copying,
streamed updates, and rejection/fallback. Module loader tests check ABI and
capability selection. These are application contracts worth keeping. General
Markdown conformance and zdraw's internal storage algorithms belong upstream;
new tests here should demonstrate a failure in the application boundary.

## Maintenance policy

- Name each scenario after an observable failure it catches. Prefer a reproduced
  regression or an explicit contract over checking incidental implementation.
- Use boundary cases and distinct behavior branches. Add a cross-product only
  when the interaction between its dimensions can cause a different failure.
- Keep command approvals, confinement, corruption recovery, and protocol
  rejection cases even when several inputs exercise similar-looking code.
- Add real terminal tests for input ownership, retained cells, and event-loop
  behavior that a curses recorder cannot establish.
- Keep benchmarks and live model evaluations separate. Use section timings to
  investigate slow checks before deleting coverage or shortening deadlines.

## Measurement

The initial complete run took 63.3 seconds on this workstation. Temporary
instrumentation attributed approximately 10.7 seconds to MCP connection waits,
6.6 to tool waits, 5.3 to remote waits, 3.6 to model discovery, 3.3 to remote
browsing, and 2.4 to context discovery. These groups account for about half the
elapsed time. The 50 fallback Markdown assertions took about 0.015 seconds.

The first fast run passed 2,287 assertions in 7.0 seconds and explicitly omitted
27 integration groups. Measurements are single local observations, not timing
budgets or claims about other machines. Counts can also vary with available
native capabilities. See the runner's final summary for the current result.

## Validation

`make test` passed 2,955 assertions in 62.9 seconds with no integration groups
omitted. Comparing the assertion labels before and after found no changes
outside the header geometry cases: 63 matrix assertions were removed and 12
boundary assertions added. The fast selection also passed.

Temporary test copies deliberately restored internal bracket padding and a
status-dependent identity budget. The consolidated checks rejected both
regressions and the runner exited nonzero. An unknown runner option was rejected
with usage and exit status 2. Syntax/wordcode compilation and the existing Zsh
5.8 compilation smoke check passed; this audit did not run the full suite on
every supported shell or farm host.

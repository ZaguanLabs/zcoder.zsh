# Architecture

zcoder keeps transport, model orchestration, tool dispatch, persistence, and
curses separate enough to test independently while remaining a compact Zsh
application.

## Source layout

```text
zcoder.zsh              CLI and curses event loop
lib/
  acp.zsh               ACP v1 stdio broker and protocol translation
  agent.zsh             Ollama messages and iterative tool loop
  commands.zsh          command catalog, palette, and context inspector
  compact.zsh           token accounting and conversation checkpoints
  goal.zsh              persistent goals and read-only completion verifier
  harnesses.zsh         external harness catalog and availability
  delegate.zsh          external harness consultations and editing workers
  http.zsh              native TCP/HTTP client
  input.zsh             multiline editor, viewport, and history
  input_queue.zsh       durable steering and queued follow-ups
  instructions.zsh      AGENTS.md discovery and prompt assembly
  json.zsh              native tokenizer, decoder, and encoder
  mcp.zsh               MCP registry, stdio brokers, and tools
  overlays.zsh          shared modal lifecycle, pickers, and approval views
  process.zsh           interactive command/search worker and process cleanup
  relay.zsh             same-host discovery, Unix sockets, and task spool
  remote.zsh            authenticated remote server and client protocol
  skills.zsh            Agent Skill discovery and progressive loading
  state.zsh             workspace/profile-scoped persistent sessions
  stream.zsh            incremental HTTP/NDJSON and local assistant previews
  tools.zsh             schemas, confinement, dispatch, and execution
  terminal.zsh          terminal capabilities and protocol decoding
  transcript.zsh        shared session transcript recording
  ui.zsh                adaptive curses layout and transcript rendering
  util.zsh              wrapping, truncation, and display helpers
tests/run.zsh           shell-level unit and integration tests
tests/benchmark.zsh     opt-in native performance measurements
```

## Library loading

`zcoder_require` sources each library at most once. The core libraries load at
startup; `acp.zsh` and `remote.zsh` load only when their modes are selected.
Server and ACP modes skip `input.zsh`, `ui.zsh`, `overlays.zsh`, `commands.zsh`, `stream.zsh`,
the terminal event handlers, and the curses/terminfo modules. They retain `transcript.zsh` for session
history. Remote handshakes load only `harnesses.zsh` for availability discovery;
`delegate.zsh` loads on the first external consultation or worker command. The
`mcp` maintenance CLI loads only the configuration and protocol libraries. Every
cross-library call into an optionally loaded library is guarded with
`$+functions`. `make compile` optionally precompiles the libraries to `.zwc`
wordcode, roughly halving launch time; a stale `.zwc` is ignored by zsh, so
recompiling is never required for correctness. Compile with the destination
host's installed Zsh. A successful build on a newer Zsh is not a substitute for
running the suite under the minimum supported Zsh 5.8 runtime.

## Interactive overlays

`overlays.zsh` owns one temporary curses window. Internal draw and input callbacks
share dynamically scoped selection, scrolling, and geometry. The loop redraws
when input or resizing changes the view and restores the underlying windows on
every exit, including failure. Model pickers, MCP inspection, and approvals use
the same lifecycle. Long approval text is wrapped again after resize; a dialog
that cannot fit never grants approval.

`commands.zsh` filters a trusted command catalog with native literal and
subsequence matching. Selection closes the palette before invoking the existing
slash-command dispatcher or preparing an argument-taking command in the editor.
Search text is never evaluated. The context inspector snapshots the existing
accounting once when opened; its draw callback only wraps that snapshot. The
component estimates and textual context bill share the same accounting values.
Unchanged serialized history records reuse cached byte and reasoning lengths;
changed records invalidate their entries. The inspector uses the prepared tool
catalog and does not start MCP discovery or a nested input loop.

Modals collect an already-running local warm-up while retaining input ownership.
Underlying status updates are deferred until the overlay closes. Model discovery
and MCP connection/restart use responsive waits outside the modal lifecycle.

## Rendering and activity input

Each curses window retains a key describing its display state. Transcript keys
use the existing generation, event count, and mutation cursor rather than copying
message bodies. Refresh calls repaint changed windows and batch them into one
physical update; an unchanged frame issues no curses calls. The input window is
refreshed last to restore its cursor without repainting unchanged text. Resize,
terminal re-entry, and modal dismissal explicitly invalidate the windows.
Ncurses continues to own terminal cell comparison and output optimization.
Wrapping, clipping, padding, and cursor layout use terminal display-cell widths.
Wide characters and combining marks are handled together; complex emoji shaping
and widths still depend on the terminal. Paste input accumulates in bounded
chunks, and layout scans character arrays with reusable cursor coordinates,
avoiding repeated scans through an ever-growing scalar.

Status presentation separates the current phase from one bounded, expiring
notice. Errors outrank warnings, and generic status events preserve detailed
transcript errors. Known activity phases add elapsed time and a four-frame ASCII
spinner to the header key; repeated phase events preserve the start time. The
existing resize/input poll drives these updates, including notice expiry, with
no separate timer process or event loop. Only the header changes for animation;
modal ownership still suppresses underlying paints. Wide local headers read
existing context and goal counters without recomputing context or making I/O.

Generation and delegate waits share one input poller with remote turns. It
supports draft editing, bracketed paste, transcript navigation/folding, and
Escape cancellation. Enter in the editor leaves the draft unsent during activity;
session changes and command dispatch remain in the idle loop. A short Escape
deadline distinguishes cancellation from terminal protocol sequences.

Remote turns poll input without blocking between nonempty events as well as
during idle responses. This prevents continuous event traffic from starving
input. Native file operations and local processing still bound how often the UI
can poll.

Interactive remote HTTP exchanges use a request-local instance
of the native HTTP worker, with its bearer header scoped to that launch. TCP and
response spooling belong to the child; approval dialogs, event cursors, and
transcript updates remain in the parent. Remote requests cannot replace an
unrelated local warm-up's worker ownership. A parent deadline covers connection,
write, and read waits, including peers that stop midway through an HTTP response.
Cleanup releases the child and spool before any subsequent request starts.

Escape during model preparation stops before prompt submission. Once a prompt
or approval may have reached the server, Escape closes that request and attempts
the existing cancel endpoint with a two-second acknowledgement deadline. The UI
reports server acknowledgement separately from an unconfirmed stop. Neither
case claims rollback, and interrupted submissions and approvals are never
replayed. Headless clients retain synchronous HTTP.

Interactive startup initializes curses before the handshake. Session lists and
transcripts stage complete pages before publication, so a failed or cancelled
load leaves the prior view usable. Session mutation attempts set an uncertainty
guard until the selected ID and transcript have both loaded. Before the next
prompt, a guarded client reads the server's current session and reconciles the
view; it never retries an uncertain create/select mutation automatically.

Idle model polling uses separate persistent PID/base ownership. Each idle tick
starts or collects at most one worker without entering an input wait. Foreground
model checks, prompts, and session mutations cancel that worker before proceeding;
endpoint changes also discard it. The parent commits model state only after a
complete response and cleans up the worker on completion, deadline, or exit.

### Interactive model discovery

Interactive Ollama model discovery uses a request-local HTTP worker and a
60-second parent deadline, independently of pending model warm-up ownership.
OpenCode catalogs use the native process runner with the same deadline. Its
explicit truncation flag lets catalog consumers reject incomplete output before
parsing; ordinary tool displays retain their bounded head/tail previews. Model
pickers publish choices only after successful discovery and preserve selection
on cancellation or failure. Headless discovery remains synchronous.

Interactive context-allocation queries (`/api/ps`) own a separate HTTP worker
with a 30-second deadline. Initial payload preparation waits through the shared
input loop; Escape propagates cancellation before generation starts. Queries
after a response or warm-up start in the background and are collected by existing
UI ticks, including modal ticks, without taking over input. Collection preserves
the caller's transport, tokenizer, and model-response state. Failed queries keep
the existing allocation or fallback estimate; unresolved auto sizing continues
to omit `num_ctx`. Model/host changes, reset, and UI shutdown discard pending
work. Headless context discovery remains synchronous.

### Interactive external processes

Local interactive `run_command`, `search`, and patch subprocesses execute argv through
`lib/process.zsh`. Validation, approvals, tool dispatch, result formatting, and
session policy remain in the parent. The worker receives no dispatcher authority.
`zsh/zpty` supplies an isolated terminal session and process group using native
Zsh facilities. Its evaluated command is a constant function name; executable
arguments are inherited as an array. Only an explicitly approved `run_command`
passes shell source to `zsh -c`.

A startup handshake publishes the worker PID before the parent admits execution.
Output goes to private files; the worker publishes a completion marker only
after writing the exit status successfully. Collection reads bounded head/tail
windows instead of loading arbitrarily large command output into the UI shell.
The worker holds its process-group identity until cleanup. Cancellation sends
TERM, allows a short grace period while polling input, then releases the owned
group with KILL. Normal completion also releases any remaining group members.
The private PTY keeps `/dev/tty` output away from the application screen.

The existing activity loop enforces the command's timeout (or 120 seconds for
search), with no external timeout utility on this interactive path. Escape
records the cancellation, closes remaining calls in that model response as
unexecuted, and ends the turn. Cancellation during verifier search follows the
existing goal-pause path. Completed side effects are never reported as rolled
back. Server, ACP, and one-shot execution retain their existing synchronous path.

Patch execution keeps validation, engine selection, workspace checks, and the
patch-retry guard in the parent. Its process wrapper distinguishes ordinary
rejection from cancellation, timeout, or worker failure. Only ordinary rejection
permits fallback to another engine; an interrupted mutation is never retried
implicitly. Function-local `always` cleanup removes patch scratch files.

### Interactive MCP calls

`mcp_call_tool` opts its broker request into the shared activity wait. The broker
continues to own server stdio and JSON-RPC correlation; the parent retains the
connection registry, approvals, and result parsing. Headless transport waits
keep their existing behavior. Cancellation and transport
failure disconnect the affected broker, clear its ownership entries, and mark
the server for reconnection. The tool round stops on cancellation without replay.
Outcomes of external mutations remain explicitly uncertain after disconnection.

Broker children clear inherited UI/session traps. Parent-side shutdown is
bounded even if the broker is stuck reading a partial line, and the interactive
shutdown grace period continues polling input. A subsequent connection starts
with a fresh broker and clears old spool responses.

Interactive connection setup uses the same wait callbacks for broker readiness,
modern/legacy negotiation, and each tools/list page. Dynamically scoped connection
state distinguishes a cancelled or broken transport from a valid protocol
rejection, so only the latter can attempt legacy negotiation. Cancellation stops
the remaining connection pass and propagates through schema and payload builders
before a prompt, warm-up, or compaction can issue a model request. Partial tool
pages remain local until the complete catalog is ready. The MCP inspector releases
its overlay before restarting a server, then recreates it after connection setup.

### Optional terminal protocol ownership

`lib/terminal.zsh` owns bracketed paste and optional mode 2026 synchronization.
All curses refreshes pass through its balanced begin/end wrapper; all UI input
passes through its bounded CSI decoder before reaching editors or modals. The
decoder consumes capability replies (including late replies) so their final `y`
cannot approve a command. Other sequences are queued unchanged, and protocol
lookalikes inside bracketed paste remain text. Detection shares the existing
event loop and never adds a startup wait or worker-owned terminal output.

## Agent cycle

Both profiles teach the model a small operating loop:

```text
OBSERVE → DECIDE → ACT → CHECK
```

The model inspects until it has enough evidence, chooses one useful next action,
and verifies changes in proportion to their risk. The agent has no fixed model
turn ceiling; it continues while progress is being made.

Ordinary local TUI turns request streaming unless `ZCODER_STREAM=false`.
Structured routing, compaction, goals/verifiers, LFM normalization, and headless
transports retain buffered requests. The HTTP request still runs in a background
Zsh worker; stopping it closes the TCP connection and cancels Ollama's request.

`stream.zsh` incrementally decodes chunked, Content-Length, or connection-close
HTTP bodies. The worker writes decoded bytes to a private append-only spool;
the parent owns a reader descriptor marked close-on-exec. It reads at most
32 KiB and processes at most 64 NDJSON records per activity poll. Partial records
and UTF-8 byte sequences survive read boundaries. Framing has explicit size
bounds, and completion metadata is published only after checked writes.

The accumulator follows Ollama's native [streaming format](https://docs.ollama.com/capabilities/streaming):
content, thinking, and complete tool-call objects accumulate in order; the final
`done:true` record supplies usage. Missing completion, malformed records, and
incomplete HTTP framing fail the request. No tool is dispatched from a partial
stream. The assembled response passes through the existing agent validation,
history, and approval paths.

Live text updates one transcript preview. Accepted assistant output adopts it;
interrupted previews are explicitly marked as partial and do not enter model
history. Completed responses retain the existing recovery rules when the agent
rejects their proposed action or answer. Saved in-flight previews restore as interrupted. Every
terminal result releases the request worker, reader descriptor, and spool.
Reasoning, content, tool calls, and tool results remain together in subsequent
model requests.

Every Ollama chat payload has exactly one `system` record, at the beginning.
Runtime recovery instructions and external-harness results are added as clearly
labelled user-role context without entering the exact-user ledger.
When an older saved session contains a mid-conversation system record, the
transport normalizes that record to a user role while building the request.
This keeps persisted sessions compatible with strict model templates that
reject system messages anywhere except the first position.

## ACP transport

`lib/acp.zsh` is a newline-delimited JSON-RPC v1 broker. It translates ACP
sessions, prompt content, streamed message updates, tool lifecycle events,
permissions, and cancellation into the same state, agent, and tool functions
used by the TUI. The broker owns stdio while each active prompt runs in a Zsh
coprocess, keeping client responses and cancellation observable during a turn.
Both channels retain partial byte frames and process bounded batches of complete
lines. A readable descriptor does not imply a complete JSON line. ACP permission
responses must match the currently outstanding request ID and session; an
`allow-always` result can change session policy only when that exact request
offered the option. Completion and cancellation clear the pending permission.

In direct mode, ACP session setup chooses the confined local workspace and may
add client-forwarded stdio MCP servers. In remote-client mode, the broker maps
ACP calls onto `lib/remote.zsh`; the remote server remains authoritative for the
workspace, model, instructions, Skills, MCP configuration, tools, persistence,
and command policy. Structured remote tool events are opt-in per turn so older
protocol-1 clients see an unchanged event stream.

Before the first local interactive turn, zcoder uses the same asynchronous HTTP
worker for a disposable warm-up request. It includes the resolved system prompt
and tool schema but excludes saved conversation history. The TUI polls that
request from its normal input loop, so editing remains responsive. A real user
turn supersedes an unfinished warm-up because generation and warm-up share one
worker slot. Model and context discovery own separate workers. Warm-up output
is validated and discarded;
it never enters agent or session state.

MCP broker responses likewise use bounded byte reads and keep the exchange
deadline active across partial lines. Response matching reads only top-level
JSON-RPC IDs and methods, so nested tool-result fields cannot redirect a reply.
An uncertain failed exchange disconnects the broker, including in headless mode.
These read-side changes do not make every pipe or network write asynchronous.

## Same-host agent relay

Eligible local interactive processes lazily load `relay.zsh`, validate a
same-user registry, start a background Unix-socket listener, and publish a
small manifest. Discovery validates bounded manifests and pings the exact
instance ID. The listener performs framing, validation, deduplication, queue
limits, atomic spooling, and acknowledgement only.

The curses process claims at most one queued envelope before reading the next
keyboard event. It records a distinct relay transcript event and passes a fixed
untrusted-context wrapper through the common agent loop. Relayed content stays
out of the exact-user ledger and cannot set a session title. Because agent,
session, and UI mutation stays in the foreground, a busy receiver can accept
messages without concurrent conversation mutation.

## External harnesses

Plain provider commands run read-only consultations. A bang command selects an
explicit execution mode for that invocation: Codex `workspace-write`, Claude
`acceptEdits` with focused coding tools, Antigravity `accept-edits` plus its
sandbox, or OpenCode's `build` agent. Both modes share the asynchronous process,
timeout, cancellation, JSON/JSONL decoding, and output-bounding pipeline.

Consultant output is retained as untrusted reference material. Execution output
uses a distinct worker transcript role and is retained as an untrusted report
which tells the Ollama agent that the workspace may have changed. The report is
context, not proof: follow-up work must inspect current files and Git state.
External workers use their harness's permission system rather than zcoder's
`run_command` approval path, and interrupted runs do not roll back completed
edits. Execution mode is rejected in the `sysadmin` profile because its
per-command approval invariant cannot be delegated to those harnesses.

Availability is a fixed provider catalog backed by Zsh's command table. Local
invocations refresh it before dispatch. Remote servers serialize the installed
provider names as a stable comma-separated handshake field, which the client
restores without consulting its own `PATH`. Both modes use one formatter for
help text and unavailable-command errors. Protocol-1 peers that omit the field
remain compatible and are treated as availability unknown.

## Built-in tools

| Tool | Purpose | Implementation |
| --- | --- | --- |
| `list_files` | Discover a bounded workspace tree | `rg --no-config --no-follow --files --no-require-git` plus Zsh formatting |
| `read_file` | Read a complete small text file | `zsh/mapfile` |
| `read_file_range` | Read numbered inclusive lines | Block reads, native line splitting, bounded head-and-tail output |
| `write_file` | Create or deliberately replace a file | Confined `zsh/system` descriptor writes |
| `replace_text` | Replace one unique exact text fragment | Native Zsh matching and confined writes |
| `apply_patch` | Apply a unified or context diff | `git apply`, then `patch` fallback |
| `search` | Search text with locations | `rg --no-config --no-follow` |
| `run_command` | Run builds, tests, and diagnostics | Approved `zsh -c` |
| `list_agents` | Discover live same-user local peers | Private manifests plus protocol ping |
| `send_agent_message` | Queue a task for one exact peer | Framed Unix-domain socket request |
| `discover_skills` | Search omitted Skill metadata when the visible catalog is truncated | Native Zsh matching |
| `activate_skill` | Load selected Skill instructions | Native Skill discovery |
| `read_skill_resource` | Read an active Skill resource | Canonicalized read-only access |
| `finish` | Complete or block a turn structurally | Agent-loop control |

`list_files` and `search` honor nested `.gitignore` files even outside a Git
repository and skip common dependency and build directories. The prompt directs
the model to search first, then read relevant ranges rather than whole large
files. Ripgrep configuration is disabled explicitly: inherited `--follow` and
`--pre` options cannot weaken workspace confinement or execute a preprocessor
through a read tool. A root workspace of `/` uses the same descendant check.

Ranged reads count preceding lines in 32 KiB blocks and stop reading once the
requested final line is complete. A trailing newline terminates its preceding
line rather than creating another line. Returned output retains bounded first
and last sections; a single selected long line is still assembled before output
truncation, so memory for that line follows its length.

`replace_text` is the low-complexity path for a small literal edit. It fails
closed when the old text is absent or occurs more than once, so the model must
read the target and supply a unique exact fragment.

Patch application does not require a Git repository. zcoder validates with
`git apply --check`; if Git rejects an otherwise usable diff, it tries a
workspace-confined `patch --dry-run`. After a rejected patch, `write_file` and
`replace_text` are removed for the rest of that user turn until a corrected
patch succeeds.
The `apply_patch` tool schema and rejection result use the same unified-diff
contract; the system prompt points to that single model-visible definition
instead of duplicating it. It includes a valid and invalid example, explains
numeric hunk counts and line prefixes, and explicitly rejects Markdown fences,
bare `@@`, placeholders, and `*** Begin Patch`-style harness envelopes.

## JSON and buffered HTTP validation

The shared JSON tokenizer accepts the JSON number grammar and only space, tab,
CR, and LF as whitespace. It rejects trailing container commas and literal
U+0000 through U+001F inside strings. Public object parsers require end of input;
invalid suffixes cannot be silently ignored. Escaped unpaired UTF-16 surrogates
retain the existing replacement-character behavior. DEL is legal literal JSON.
Encoding uses native split/join transforms, including uncommon controls, rather
than indexing every character in a growing Unicode scalar.

The buffered HTTP decoder validates chunk sizes, data CRLF delimiters, and the
terminal zero chunk. Missing completion fails the response even when earlier
chunks were complete. This complements the incremental framing checks in
`stream.zsh`.

## Multiple tool calls

One assistant response may contain multiple tool calls. zcoder executes them
sequentially in the model's emitted order and returns every result to Ollama,
matching its multi-call protocol while preserving deterministic history. Each
call independently passes its normal argument validation, workspace boundary,
safety guard, and approval policy. A failed or unknown call produces its own
tool result without replacing the results of the other calls.

This supports both independent reads and ordered sequences such as writing a
file and then running its syntax check. `finish` remains a turn-control tool and
must be the only call in its response; when mixed with work calls, only the
`finish` call is rejected so the completed work and its results remain visible
to the model.

Normal turns request at most `ZCODER_MAX_OUTPUT_TOKENS` tokens. Automatic
compaction reserves that output allowance when choosing its trigger, which is
especially important at the supported 32K floor. `/context` attributes the
current estimated prompt across base guidance, project instructions, Skills,
MCP guidance, checkpoint state, schemas, and role-specific history.

## Loop detection and completion

The agent watches recent tool rounds for repetition. Three identical
request-and-result cycles trigger a recovery warning. Repeated requests whose
outputs change receive a more tolerant fourth repetition. Alternating cycles up
to four rounds long are also detected. The first detection gives the model one
explicit final recovery turn and records the next tool round that would
continue the cycle. A materially different tool or argument set clears the
warning and keeps the conversation running. If the model requests the forbidden
cycle step again, zcoder rejects it before tool dispatch and stops the run.

When work is complete or genuinely blocked, the model may call `finish` as its
only tool with a status and final response. A non-empty tool-free response is
also accepted because some otherwise capable local models do not reliably call
`finish`. Empty or malformed responses receive a bounded retry budget.
Transient connection failures before an HTTP response receive one bounded
replay of the unchanged model request. Response timeouts are reported
separately and are not replayed, because restarting a long-running generation
would discard work and repeat the same load.

LFM-family models sometimes return their planner envelope as ordinary JSON
content instead of using Ollama's native `tool_calls` field. zcoder explicitly
instructs these models to use only Ollama's native action channel. Content JSON
is never converted into an executable action; recognized planner shapes and
false claims that supplied tools are unavailable receive a bounded native-tool
retry instead.

When a native LFM tool call includes non-empty assistant content, the native
call remains authoritative and that incidental content is retained only as
private, collapsible reasoning. A leading `<think>...</think>` block is also
separated from a tool-free final answer. Other model families and ordinary JSON
answers keep the standard adaptive completion behavior. Explicit requests for
a plan without execution or for a JSON-only response bypass LFM recovery.

Set `ZCODER_REQUIRE_FINISH_TOOL=1` for strict structural completion. Setting
`ZCODER_INCOMPLETE_RETRY_LIMIT=0` disables recovery attempts, not strict completion:
a response without the required `finish` fails immediately. Active goals keep
the same requirement and cannot bypass independent verification through a
zero-retry setting.

## Persistent goal loop

`/goal OBJECTIVE` changes completion from a single model decision into a
persisted worker/verifier loop:

```text
objective → work → candidate finish → read-only verification
                ↑                         │
                └──── rejection feedback ┘
```

An active goal always requires `finish` as the only completion tool. A
`complete` finish is a candidate, not the terminal result. zcoder forks the
current transcript into a separate Ollama inference with a verifier-only system
prompt and only `list_files`, `read_file`, `read_file_range`, and `search` for
evidence. The verifier must return `verify_goal` with `accept` or `reject`.
Verifier tool dispatch is a separate allowlist, so an invented write, MCP,
relay, or command call is rejected even though it was not advertised.

Acceptance records the goal as complete. Rejection adds the reason, next
action, and missing evidence to the worker history and resumes the same goal
from current memory and workspace state. Three rejected candidates stop as
blocked by default. A worker-reported genuine blocker, repeated tool loop,
repeated patch failure, transport/compaction failure, verifier failure, or
optional token limit also stops safely. Escape pauses local and remote goal
work; `/goal resume` begins a fresh rejection audit without changing the saved
objective. Resuming a token-limited stop removes the exhausted limit.

Goal metadata, objective, feedback, candidate counts, and cumulative Ollama
token counts live with the saved session. Compaction cannot erase the objective
because the active goal prompt injects it into every worker request. A session
loaded after an interrupted worker or verifier is marked paused rather than
silently pretending the loop is still running.

## Session persistence

Each session directory has an atomically replaced `current` file identifying
one committed directory below `generations/`. A save writes its metadata and
manifests with checked writes before publishing that pointer. The manifests
reference immutable message, UI, user-ledger, and active-Skill records. Unchanged
records can be reused from prior generations; readers resolve one committed
snapshot instead of mixing independently rewritten files.

Publication holds the session's exclusive writer lock. Readers hold a shared
lease on the same lock throughout snapshot access, including history, summaries,
and queued-input recovery. Generation collection runs under the writer lock
after publication when more than 32 manifest generations exist. It retains the
current and previous manifests plus every immutable record they reference.
Older directories can remain when they contain referenced records; the policy
bounds obsolete manifests rather than promising exactly two directories.

Legacy sessions remain readable until their first generation save, which keeps
the original files while migrating. A malformed `current` marker is an error,
not a reason to silently load older legacy content. Atomic publication protects
against interrupted processes, but there is no `fsync` power-loss guarantee.
Older binaries cannot read the generation format. Back up session storage before
upgrading; downgrading requires explicitly restoring compatible legacy data and
loses work newer than that backup. Preserve a copy of newer storage before any
restore. There is no automatic downgrade. See the
[v0.12.2 upgrade precautions](releases/v0.12.2.md#session-storage-and-upgrade-precautions).

## Remote transport

Remote mode moves the complete agent loop behind a small authenticated HTTP API.
The local TUI submits a turn and polls ordered, sequence-numbered events. A
server worker owns the Ollama request, tools, and session state.

Protocol-1 handshakes advertise goal support with `"goals":true`. Goal slash
commands use the ordinary authenticated turn/event channel, and older servers
that omit the capability remain usable but reject goal commands client-side.

The initial handshake and every turn boundary check whether the server's
configured model is resident in Ollama. An absent model is warmed
asynchronously with the same disposable stable-prefix request used locally,
and the client polls explicit model status for its `[ Warming Up ]` badge. The
server does not warm models merely because configured server processes exist.
If eviction races with prompt submission, the prompt is stored privately and
starts only after warm-up succeeds.

Background warm-up and turn processes explicitly close their inherited listener
and accepted-request descriptors before contacting Ollama. The listener can
therefore finish the handshake or `202 Accepted` response immediately while the
child continues, allowing the client to poll status and command-approval events
without a circular socket wait.

Command approval is an explicit protocol event. The worker pauses until the
client sends a decision tied to the active one-use identifier. Cancellation
terminates and reaps the worker. Runtime events are published atomically through
private files, while the conversation uses the normal persistent session format.
Visible worker events are appended to that format as well as streamed to the
connected client, so reconnecting restores the transcript instead of only the
model's hidden conversation history.

Session ownership remains on the server. Cursor-based endpoints expose bounded
session summaries and transcript events to the client, and authenticated
selection/new-session requests update the named server's selected job. The
client keeps only the sidebar and transcript view in memory; it does not write a
second local copy of remote state. A new client launch requests a fresh job,
while reusing an already-empty selected job to avoid accumulating duplicate
blank sessions.

The server accepts one active turn at a time. The session owner can receive
steering at response/tool-batch boundaries and run queued follow-ups before
ending that run. `lib/input_queue.zsh` provides a shared private file queue for
the TUI, HTTP broker, and ACP broker, protected by `zsystem flock`. Brokers only
publish input; the owner records user messages and durable consumption receipts.
See [queued-input storage and recovery](queued-input.md#implementation).

See [Remote-agent server](remote.md)
for operation and security constraints.

[Documentation index](README.md) · [Development](development.md) · [Project README](../README.md)

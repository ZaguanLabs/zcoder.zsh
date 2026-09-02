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
  compact.zsh           token accounting and conversation checkpoints
  goal.zsh              persistent goals and read-only completion verifier
  delegate.zsh          external harness consultations and editing workers
  http.zsh              native TCP/HTTP client
  input.zsh             multiline editor, viewport, and history
  instructions.zsh      AGENTS.md discovery and prompt assembly
  json.zsh              native tokenizer, decoder, and encoder
  mcp.zsh               MCP registry, stdio brokers, and tools
  relay.zsh             same-host discovery, Unix sockets, and task spool
  remote.zsh            authenticated remote server and client protocol
  skills.zsh            Agent Skill discovery and progressive loading
  state.zsh             workspace/profile-scoped persistent sessions
  tools.zsh             schemas, confinement, dispatch, and execution
  ui.zsh                adaptive curses layout and approval modal
  util.zsh              wrapping, truncation, and display helpers
tests/run.zsh           shell-level unit and integration tests
```

## Library loading

`zcoder_require` sources each library at most once. The core libraries load at
startup; `acp.zsh` and `remote.zsh` load only when their modes are selected, and
`delegate.zsh` loads on the first external consultation or worker command. The
`mcp` maintenance CLI loads only the configuration and protocol libraries. Every
cross-library call into an optionally loaded library is guarded with
`$+functions`. `make compile` optionally precompiles the libraries to `.zwc`
wordcode, roughly halving launch time; a stale `.zwc` is ignored by zsh, so
recompiling is never required for correctness.

## Agent cycle

Both profiles teach the model a small operating loop:

```text
OBSERVE → DECIDE → ACT → CHECK
```

The model inspects until it has enough evidence, chooses one useful next action,
and verifies changes in proportion to their risk. The agent has no fixed model
turn ceiling; it continues while progress is being made.

Agent turns currently send `stream: false` to Ollama. In the TUI, the HTTP
request runs in a background Zsh worker so the interface can accept Escape.
Stopping the worker closes the TCP connection and cancels Ollama's request.

Non-streaming does not flatten the reasoning lifecycle. zcoder stores each
assistant's reasoning, content, and structured tool calls together, appends tool
results, and returns that complete history on the next model step.

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
turn supersedes an unfinished warm-up because the HTTP worker deliberately owns
only one Ollama request at a time. Warm-up output is validated and discarded;
it never enters agent or session state.

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
| `list_files` | Discover a bounded workspace tree | `rg --files --no-require-git` plus Zsh formatting |
| `read_file` | Read a complete small text file | `zsh/mapfile` |
| `read_file_range` | Read numbered inclusive lines | Native Zsh splitting and indexing |
| `write_file` | Create or deliberately replace a file | Confined `zsh/system` descriptor writes |
| `replace_text` | Replace one unique exact text fragment | Native Zsh matching and confined writes |
| `apply_patch` | Apply a unified or context diff | `git apply`, then `patch` fallback |
| `search` | Search text with locations | `rg` |
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
files.

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

Set `ZCODER_REQUIRE_FINISH_TOOL=1` for strict structural completion.

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

The server accepts one active turn at a time. See [Remote-agent server](remote.md)
for operation and security constraints.

[Documentation index](README.md) · [Development](development.md) · [Project README](../README.md)

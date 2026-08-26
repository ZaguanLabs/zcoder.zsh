# Architecture

zcoder keeps transport, model orchestration, tool dispatch, persistence, and
curses separate enough to test independently while remaining a compact Zsh
application.

## Source layout

```text
zcoder.zsh              CLI and curses event loop
lib/
  agent.zsh             Ollama messages and iterative tool loop
  compact.zsh           token accounting and conversation checkpoints
  delegate.zsh          read-only external harness consultations
  http.zsh              native TCP/HTTP client
  input.zsh             multiline editor, viewport, and history
  instructions.zsh      AGENTS.md discovery and prompt assembly
  json.zsh              native tokenizer, decoder, and encoder
  mcp.zsh               MCP registry, stdio brokers, and tools
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
startup; `remote.zsh` loads only when a remote mode is selected, and
`delegate.zsh` loads on the first external-consultation command. The `mcp`
maintenance CLI loads only the configuration and protocol libraries. Every
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

Before the first local interactive turn, zcoder uses the same asynchronous HTTP
worker for a disposable warm-up request. It includes the resolved system prompt
and tool schema but excludes saved conversation history. The TUI polls that
request from its normal input loop, so editing remains responsive. A real user
turn supersedes an unfinished warm-up because the HTTP worker deliberately owns
only one Ollama request at a time. Warm-up output is validated and discarded;
it never enters agent or session state.

## Built-in tools

| Tool | Purpose | Implementation |
| --- | --- | --- |
| `list_files` | Discover a bounded workspace tree | `rg --files --no-require-git` plus Zsh formatting |
| `read_file` | Read a complete small text file | `zsh/mapfile` |
| `read_file_range` | Read numbered inclusive lines | Native Zsh splitting and indexing |
| `write_file` | Create or deliberately replace a file | `zsh/mapfile` and `zsh/files` |
| `apply_patch` | Apply a unified or context diff | `git apply`, then `patch` fallback |
| `search` | Search text with locations | `rg` |
| `run_command` | Run builds, tests, and diagnostics | Approved `zsh -c` |
| `activate_skill` | Load selected Skill instructions | Native Skill discovery |
| `read_skill_resource` | Read an active Skill resource | Canonicalized read-only access |
| `finish` | Complete or block a turn structurally | Agent-loop control |

`list_files` and `search` honor nested `.gitignore` files even outside a Git
repository and skip common dependency and build directories. The prompt directs
the model to search first, then read relevant ranges rather than whole large
files.

Patch application does not require a Git repository. zcoder validates with
`git apply --check`; if Git rejects an otherwise usable diff, it tries a
workspace-confined `patch --dry-run`. After a rejected patch, `write_file` is
removed for the rest of that user turn until a corrected patch succeeds.

## Multiple tool calls

One assistant response may contain multiple independent read-only built-ins or
`run_command` calls. zcoder executes every accepted call sequentially and
returns every result to Ollama, matching its parallel-tool-call protocol while
preserving deterministic history. Each command independently passes workspace
validation, safety guards, and the configured command approval policy before
execution.

A batch containing an edit, activation, `finish`, unknown tool, or MCP tool
without explicit read-only metadata is rejected before any call runs. Dependent
operations and state-changing commands still require separate reasoning cycles.

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

LFM-family models sometimes return their planner envelope as ordinary JSON
content instead of using Ollama's native `tool_calls` field. For those models,
zcoder recognizes `actions`, `tool_call(s)`, and `commands` planner shapes and
normalizes one action at a time into the regular tool pipeline. Shell-like
`command` or `keystrokes` entries become `run_command` calls, so workspace
validation, safety guards, and command approval still apply. Malformed planner
JSON and false claims that the supplied tools are unavailable receive a bounded
native-tool retry; the planner text is never displayed as a completed answer.
Other model families and ordinary JSON answers keep the standard adaptive
completion behavior. Explicit requests for a plan without execution or for a
JSON-only response also bypass LFM action promotion.

Set `ZCODER_REQUIRE_FINISH_TOOL=1` for strict structural completion.

## Remote transport

Remote mode moves the complete agent loop behind a small authenticated HTTP API.
The local TUI submits a turn and polls ordered, sequence-numbered events. A
server worker owns the Ollama request, tools, and session state.

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

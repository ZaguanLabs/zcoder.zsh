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

## Batched reads and serialized changes

One assistant response may contain multiple independent read-only built-ins:
`list_files`, `read_file`, `read_file_range`, `search`, and
`read_skill_resource`. zcoder executes accepted calls sequentially to preserve
deterministic history.

A batch containing an edit, command, approval, activation, `finish`, unknown
tool, or MCP tool without explicit read-only metadata is rejected before any
call runs. Dependent reads and every state-changing operation therefore require
separate reasoning cycles.

## Loop detection and completion

The agent watches recent tool rounds for repetition. Three identical
request-and-result cycles trigger a recovery warning. Repeated requests whose
outputs change receive a more tolerant fourth repetition. Alternating cycles up
to four rounds long are also detected. If the model repeats the pattern after
the warning, the run stops.

When work is complete or genuinely blocked, the model may call `finish` as its
only tool with a status and final response. A non-empty tool-free response is
also accepted because some otherwise capable local models do not reliably call
`finish`. Empty or malformed responses receive a bounded retry budget.

Set `ZCODER_REQUIRE_FINISH_TOOL=1` for strict structural completion.

## Remote transport

Remote mode moves the complete agent loop behind a small authenticated HTTP API.
The local TUI submits a turn and polls ordered, sequence-numbered events. A
server worker owns the Ollama request, tools, and session state.

Command approval is an explicit protocol event. The worker pauses until the
client sends a decision tied to the active one-use identifier. Cancellation
terminates and reaps the worker. Runtime events are published atomically through
private files, while the conversation uses the normal persistent session format.

The server accepts one active turn at a time. See [Remote-agent server](remote.md)
for operation and security constraints.

[Documentation index](README.md) · [Development](development.md) · [Project README](../README.md)

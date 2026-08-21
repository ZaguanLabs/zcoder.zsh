# zcoder.zsh

`zcoder.zsh` is a Zsh-first AI coding agent for Ollama. Its full-screen interface builds on [zchat.zsh](https://github.com/ZaguanLabs/zchat.zsh), adding an iterative tool-calling loop for working on real projects.

The model can discover a workspace, read and edit files, search source, apply unified diffs, and request shell commands. File tools are confined to the selected workspace. Every shell command is gated by an explicit approval prompt.

Project guidance is loaded from `AGENTS.md` before the first model turn, with hierarchical overrides and bounded prompt size.

## Quick start

Requirements:

- Zsh 5.8 or newer, with its standard loadable modules
- a running Ollama server and a model with tool-calling support
- `ripgrep` (`rg`) for the `list_files` and `search` tools
- `git` or `patch` for the `apply_patch` tool; installing both provides the widest patch-format compatibility
- `stty` for adaptive terminal resize detection

GNU `timeout` is optional. Without it, `run_command` still works, but command time limits are not enforced. `make` and `mktemp` are needed only for development and running the test suite. Commands such as `grep`, `sed`, and `awk` may be requested by the model through the approval-gated `run_command` tool, but zcoder itself does not depend on them.

Start Ollama, pull a coding model, then run:

```sh
ollama pull qwen3-coder
git clone https://github.com/ZaguanLabs/zcoder.zsh.git
cd zcoder.zsh
./zcoder.zsh --model qwen3-coder --workspace /path/to/project
```

One-shot mode is useful for scripts and smoke tests:

```sh
./zcoder.zsh --model qwen3-coder --workspace . \
  --prompt "Inspect this project and explain how it is organized"
```

One-shot mode still asks on `/dev/tty` before running commands. `--yes` explicitly allows commands for that process; `--deny-commands` refuses them.

Agent runs have a configurable emergency ceiling of 100 model turns. Override it with `--max-turns COUNT` or `ZCODER_MAX_TURNS`; this is a final safety fuse, not the primary loop detector.

Context sizing defaults to `auto`. If the selected model is already loaded, zcoder uses the allocation reported by Ollama's `/api/ps`; otherwise it begins with a conservative 65,536-token fallback and refreshes its accounting after the first response. Use `--context-window TOKENS` or `ZCODER_CONTEXT_WINDOW` when a model should be loaded with a specific allocation from its first request.

Larger contexts consume more memory. `/context` shows the allocation and current compaction threshold.

## Agent tools

| Tool | Purpose | Implementation |
| --- | --- | --- |
| `list_files` | Discover the workspace tree | `rg --files --no-require-git`, with Zsh tree formatting |
| `read_file` | Read a complete text file | `zsh/mapfile` |
| `read_file_range` | Read inclusive numbered lines | Native Zsh splitting/indexing |
| `write_file` | Create or replace a text file | `zsh/mapfile` and `zsh/files` |
| `apply_patch` | Apply a standard unified or context diff | `git apply` with `patch` dry-run fallback |
| `search` | Regex source search with locations | `rg` |
| `run_command` | Run builds, tests, formatters, and diagnostics | `zsh -c`, after approval |
| `finish` | Complete or block the current turn with a final response | Agent-loop control protocol |

`list_files` gives the agent a bounded discovery primitive before it knows filenames or search terms.

The two read tools intentionally coexist: `read_file` is convenient for small files, while `read_file_range` lets the model keep context bounded when files are large.

The system prompt asks the model to search first—using the `search` tool backed by ripgrep—then read only relevant ranges. Whole-file reads are reserved for small files or cases where complete context is genuinely necessary. Rephrased discovery searches are discouraged once a usable location is known. Both `list_files` and `search` honor workspace and nested `.gitignore` files even when no Git repository exists and skip common dependency/build trees. `list_files` defaults to 100 entries and `search` to 50 matches. For text processing that does not fit `search`, the model may request `run_command` with `rg`, `grep`, `sed`, or `awk`; the normal command-approval gate still applies.

Successful reads are compact in the TUI: `Read(path)` and `Read File Range(path:start-end)`. The actual contents remain in model history. `write_file` and `apply_patch` continue to display their proposed content so edits stay reviewable.

`apply_patch` does not require the workspace to be a Git repository. It first validates with `git apply --check`; if Git rejects an otherwise usable diff, it tries a workspace-confined `patch --dry-run` before applying. Invalid model output returns a corrective unified-diff example so the model can retry the focused edit instead of falling back to `write_file`.

## Permission model

Read, search, and workspace edit tools execute directly. `run_command` always starts in `ask` mode and presents:

- `y`: allow this command once
- `a`: allow commands for the remainder of this process
- `n` or Escape: deny

Commands run only inside the chosen workspace (or a workspace-contained `cwd`). Tool paths are canonicalized and rejected if they resolve outside the workspace. Output returned to the model is bounded to avoid runaway context growth.

## AGENTS.md project instructions

At startup, zcoder builds an instruction chain using modern coding-agent precedence:

1. Global guidance from `$ZCODER_HOME/AGENTS.override.md`, otherwise `$ZCODER_HOME/AGENTS.md`. `ZCODER_HOME` defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/zcoder`.
2. Project guidance from the nearest Git root down to the selected workspace. Without a Git root, only the workspace directory is checked.
3. In each directory, the first non-empty match wins: `AGENTS.override.md`, `AGENTS.md`, then names configured in `ZCODER_PROJECT_DOC_FALLBACKS`.
4. Files are merged from broadest to most specific, so later nested guidance takes precedence.

The combined file-content limit defaults to 32 KiB and can be changed with `ZCODER_PROJECT_DOC_MAX_BYTES`. Fallback filenames are colon-separated:

```sh
export ZCODER_PROJECT_DOC_FALLBACKS='TEAM_GUIDE.md:.agents.md'
export ZCODER_PROJECT_DOC_MAX_BYTES=65536
```

Instructions are loaded once when zcoder starts. Audit the resolved chain without contacting Ollama:

```sh
./zcoder.zsh --workspace /path/to/project --print-instructions
```

Inside the TUI, `/instructions` lists the active sources. The base agent prompt also directs the model to check for closer instruction files before changing files in nested directories.

## Interface

The adaptive curses layout includes:

- header with model, Ollama host, workspace, and agent status
- workspace sidebar with available tools and command policy
- scrollable transcript with tool activity and collapsible reasoning
- native multiline editor with a four-line cursor-following viewport and prompt history
- command-approval modal

Keyboard shortcuts:

| Key | Action |
| --- | --- |
| Enter | Send prompt |
| Shift+Enter | Insert a newline; Alt+Enter is the fallback when the terminal cannot distinguish Shift+Enter |
| Escape | Stop the running Ollama response |
| Ctrl+O | Open the Ollama model picker |
| Ctrl+R | Toggle the latest reasoning block |
| Ctrl+N | Start a new conversation |
| Page Up / Page Down | Scroll transcript |
| Ctrl+U | Clear input |
| Ctrl+W | Delete previous word |
| Up / Down | Move within multiline input, then navigate prompt history at its boundaries |
| Ctrl+Q / Ctrl+D | Exit |

Slash commands: `/model` opens the picker; `/model NAME`, `/host HOST`, `/instructions`, `/compact`, `/context`, `/new`, `/help`, and `/quit` are also available.

## Architecture

```text
zcoder.zsh              CLI and curses event loop
lib/
  agent.zsh             Ollama messages and iterative tool loop
  compact.zsh           token accounting and conversation checkpoints
  instructions.zsh      AGENTS.md discovery, precedence, and prompt assembly
  http.zsh              native TCP/HTTP Ollama client
  json.zsh              native tokenizer, decoder, and encoder
  tools.zsh             schemas, confinement, dispatch, and execution
  ui.zsh                adaptive curses layout and approval modal
  input.zsh             native multiline editor, viewport, and history
  util.zsh              wrapping, truncation, and display helpers
tests/run.zsh           shell-level unit and integration tests
```

Agent turns currently use `stream: false`. The HTTP request runs in a background Zsh worker so the curses loop can accept Escape; stopping the worker closes its TCP connection and cancels Ollama's request. This keeps parallel tool calls and their history deterministic.

The agent separately watches recent tool rounds for real repetition. Three identical request-and-result cycles trigger a recovery warning; request cycles whose output changes get four repetitions. Cycles up to four rounds long are recognized, so alternating A/B behavior is covered. The warning is injected into the next system prompt and gives the model one chance to choose a materially different approach before the run is stopped. Tune the guard with `ZCODER_LOOP_REPEAT_LIMIT` and `ZCODER_LOOP_MAX_CYCLE`.

Turn completion uses a structural protocol rather than English phrase matching. While work remains, the model calls a work tool. When complete or genuinely blocked, it calls `finish` as the only tool with a `complete` or `blocked` status and the final user-facing response in any language. A plain tool-free response is provisional and receives up to three automatic requests to either continue work or call `finish`. This avoids guessing intent from wording, punctuation, or language. Tune the retry count with `ZCODER_INCOMPLETE_RETRY_LIMIT`; setting it to `0` restores legacy tool-free completion. Set `ZCODER_REQUIRE_FINISH_TOOL=0` to disable the structural protocol entirely.

## Debugging interrupted turns

Add `--debug` to append structured diagnostics without writing through curses:

```zsh
./zcoder.zsh --debug --model qwen3-coder --workspace /path/to/project
tail -f /tmp/zcoder-debug-${UID}.log
```

The log records session and exit state, Ollama request status, bounded raw responses, parsed content and tool-call counts, continuation decisions and reasons, and bounded tool-result summaries. Use `--debug-log PATH` or `ZCODER_DEBUG_LOG=PATH` for another location, and `ZCODER_DEBUG_MAX_CHARS` to change the per-record limit. Debug logs can contain prompts, assistant text, and tool arguments, so treat them as sensitive.

## Context compaction

Compaction uses continuation checkpoints with conservative safety margins for local models:

1. Ollama's `prompt_eval_count` calibrates a conservative pre-request token estimate. Before the first usage sample, zcoder estimates three bytes per token plus fixed chat-template headroom.
2. Automatic compaction starts at 85% of the allocated context by default. Change this with `--compact-at PERCENT` or `ZCODER_COMPACT_PERCENT`.
3. A tool-free, non-thinking Ollama turn creates a concise continuation checkpoint. Its output is capped at the smaller of 2,048 tokens or 10% of the active context.
4. The checkpoint retains the latest complete assistant/tool exchange—up to one sixth of the context or 16,384 tokens—plus a bounded exact-user ledger. This helps local models remember the operation immediately preceding compaction. The visible TUI transcript is not discarded.
5. If the checkpoint request itself is too large, oldest detailed records are omitted until the request is estimated below 85% of the window. The transcript reports when this fallback was necessary.

Use `/compact` to create a checkpoint manually and `/context` to inspect the current estimate, threshold, and checkpoint count. After compaction, the automatic trigger rearms above the new checkpoint size so it cannot immediately compact the same state again. Compacting an already-small conversation may produce a larger checkpoint; zcoder reports that case instead of pretending space was saved. Repeated compactions summarize the previous checkpoint together with newer detailed history. Any summary-based compaction can gradually lose precision across a long thread, so starting a focused new conversation remains preferable when practical.

## Development

```sh
make test
```

The tests cover native JSON decoding, token accounting and compaction, path confinement, file reads and writes, search, patch application, loop detection, cancellation, and both denied and allowed command execution.

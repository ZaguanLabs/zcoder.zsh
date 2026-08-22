# zcoder.zsh

`zcoder.zsh` is a Zsh-first AI coding agent for Ollama. Its full-screen interface builds on [zchat.zsh](https://github.com/ZaguanLabs/zchat.zsh), adding an iterative tool-calling loop for working on real projects.

The model can discover a workspace, read and edit files, search source, apply unified diffs, and request shell commands. File tools are confined to the selected workspace. Every shell command is gated by an explicit approval prompt.

Project guidance is loaded from `AGENTS.md` before the first model turn, with hierarchical overrides and bounded prompt size. Standard [Agent Skills](https://agentskills.io) are discovered from shared project and user locations and loaded progressively when relevant.

## Quick start

Requirements:

- Zsh 5.8 or newer, with its standard loadable modules
- a running Ollama server and a model with tool-calling support
- `ripgrep` (`rg`) for the `list_files` and `search` tools
- `git` or `patch` for the `apply_patch` tool; installing both provides the widest patch-format compatibility
- `stty` for adaptive terminal resize detection

GNU `timeout` is optional. Without it, `run_command` still works, but command time limits are not enforced. `make` and `mktemp` are needed only for development and running the test suite. Commands such as `grep`, `sed`, and `awk` may be requested by the model through the approval-gated `run_command` tool, but zcoder itself does not depend on them.

Claude Code, Codex, Google Antigravity, and OpenCode are optional. When their CLIs are installed, zcoder can invoke them as read-only consultants through slash commands; they are not required for the Ollama agent.

The Skills CLI from [skills.sh](https://skills.sh) is optional. zcoder consumes standard installed Skill directories directly and does not require Node.js or `npx` at runtime.

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

## Prompt profiles

The default `coding` profile is the project-oriented coding agent described below. Select the separate system-maintenance profile with:

```sh
./zcoder.zsh --profile sysadmin --model qwen3-coder \
  --workspace /path/to/maintenance-workspace
```

The sysadmin prompt starts with read-only diagnosis, least privilege, one reviewable change at a time, rollback planning, configuration validation, secret redaction, and explicit rules for disruptive subsystems such as storage, networking, SSH, boot, authentication, and critical services. The normal hierarchical `AGENTS.md` chain is still appended, so the maintenance workspace can supply machine-specific procedures. Those instructions may make policy stricter but cannot relax the profile's safety and approval rules.

Workspace file tools remain confined to the selected maintenance workspace. Host inspection and changes must use `run_command`. In the sysadmin profile every exact command requires separate approval: session-wide approval is unavailable, `--yes` and `ZCODER_COMMAND_POLICY=allow` are rejected, and the confirmation dialog has no “allow session” choice.

An additional pre-execution guard rejects unmistakably catastrophic literal commands such as broad root/home/workspace deletion, filesystem formatting, raw block-device writes, device shredding, and storage-pool or logical-volume destruction. It also inspects commands nested in common `sh -c` forms. This guard is intentionally conservative rather than a complete shell security parser; always inspect the exact approval request, especially when variables, scripts, interpreters, or privileged utilities are involved.

Set `ZCODER_PROFILE=sysadmin` to make the profile the environment default. `--profile coding` selects the original coding prompt explicitly. The existing `-p, --prompt TEXT` option remains the one-shot user request and is independent of the profile.

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
| `activate_skill` | Load matching Agent Skill instructions on demand | Native Zsh discovery and frontmatter parsing |
| `read_skill_resource` | Read a referenced file from an active Skill | Read-only, canonicalized Skill-root access |
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

Commands run only inside the chosen workspace (or a workspace-contained `cwd`). General file-tool paths are canonicalized and rejected if they resolve outside the workspace. `read_skill_resource` has a separate read-only boundary: it accepts only relative paths inside a discovered and activated Skill directory, rejects escaping symlinks, and cannot write. Output returned to the model is bounded to avoid runaway context growth.

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

## Agent Skills

zcoder implements the open Agent Skills format with progressive disclosure. At startup it parses only each valid `SKILL.md` name and description. The compact catalog tells the model which capabilities exist; the full Markdown body enters context only after the model calls `activate_skill` or the user activates it explicitly. Referenced scripts, documentation, and assets are read individually with `read_skill_resource` instead of being loaded eagerly.

Only the shared standard locations are scanned:

- project: `<project-root>/.agents/skills/<name>/SKILL.md`
- user: `~/.agents/skills/<name>/SKILL.md`
- user config: `${XDG_CONFIG_HOME:-$HOME/.config}/agents/skills/<name>/SKILL.md`

Project Skills override same-named user Skills. Model disclosure is bounded by `ZCODER_MAX_SKILLS` (default 128) and `ZCODER_SKILL_CATALOG_MAX_BYTES` (default 32 KiB), each activated body by `ZCODER_SKILL_MAX_BYTES` (default 32 KiB), all active bodies together by `ZCODER_ACTIVE_SKILLS_MAX_BYTES` (default 64 KiB), and simultaneous active Skills by `ZCODER_MAX_ACTIVE_SKILLS` (default 8). The activation-tool enum contains exactly the disclosed names. Active instructions are kept in the system prompt, deduplicated, and therefore survive conversation compaction; `/new` clears them.

Audit discovery without contacting Ollama:

```sh
./zcoder.zsh --workspace /path/to/project --print-skills
```

Inside the TUI, `/skills` lists discovered and active Skills, `/skills reload` rescans the standard locations, and `/skill NAME` activates one. Prefix a normal request with `$skill-name` to activate it before the first model turn. Otherwise, the model selects a Skill from its description and activates it itself.

Skill files and bundled scripts are potentially untrusted. Their instructions cannot override the base profile, AGENTS.md, workspace/write boundaries, sysadmin restrictions, or command approval. The experimental `allowed-tools` frontmatter field is intentionally not treated as permission. Executing a bundled script still requires an ordinary approved `run_command`.

## Interface

The adaptive curses layout includes:

- header with model, Ollama host, workspace, and agent status
- workspace sidebar with available tools and command policy
- scrollable transcript with tool activity and collapsible reasoning
- native syntax highlighting for `write_file` previews and semantic diff colors for `apply_patch`
- native multiline editor with a four-line cursor-following viewport and prompt history
- command-approval modal

Keyboard shortcuts:

| Key | Action |
| --- | --- |
| Enter | Send prompt |
| Shift+Enter | Insert a newline; Alt+Enter is the fallback when the terminal cannot distinguish Shift+Enter |
| Escape | Stop the running Ollama response or external consultation |
| Ctrl+O | Open the Ollama model picker |
| Ctrl+R | Toggle the latest reasoning block |
| Ctrl+N | Start a new conversation |
| Page Up / Page Down | Scroll transcript |
| Ctrl+U | Clear input |
| Ctrl+W | Delete previous word |
| Up / Down | Move within multiline input, then navigate prompt history at its boundaries |
| Ctrl+Q / Ctrl+D | Exit |

Slash commands: `/model` opens the picker; `/model NAME`, `/host HOST`, `/instructions`, `/skills`, `/skills reload`, `/skill NAME`, `/compact`, `/context`, `/new`, `/help`, and `/quit` are also available.

## External consultants

The optional delegate commands ask another installed coding harness for a second opinion without handing its edits back to zcoder:

```text
/claude Review the authentication change for edge cases
/codex Find the likely cause of this failing test
/agy Suggest the smallest safe refactor
/opencode Compare these two implementation approaches
```

Claude uses `claude-opus-5` at medium effort with only its read, glob, and grep tools. Codex uses `gpt-5.6-sol` at medium reasoning in its read-only sandbox. Antigravity uses `gemini-3.7-flash-medium` at medium effort in plan+sandbox mode. OpenCode uses its plan agent and a selected `provider/model`; run `/opencode` without a request to open the picker, or set one directly with `/opencode-model PROVIDER/MODEL`.

The defaults can be changed with `ZCODER_CLAUDE_MODEL`, `ZCODER_CODEX_MODEL`, `ZCODER_AGY_MODEL`, and `ZCODER_OPENCODE_MODEL`. `ZCODER_OPENCODE_VARIANT` passes an optional OpenCode model variant. Consultations time out after 1,800 seconds by default (`ZCODER_DELEGATE_TIMEOUT_SECONDS`). Escape cancels the running CLI and its result is not retained.

Successful CLI output is decoded from JSON or JSONL, displayed as a consultant response, and retained with its request as explicitly untrusted reference material for later Ollama turns. The visible result defaults to at most 32,768 characters; the copy retained in model context defaults to 12,000, with the original request capped separately at 2,000. Configure these with `ZCODER_DELEGATE_MAX_OUTPUT`, `ZCODER_DELEGATE_HISTORY_CHARS`, and `ZCODER_DELEGATE_REQUEST_CHARS`. A delegated harness is never invoked through `run_command`, never inherits zcoder's command-approval override, and this first implementation has no worker/edit mode.

## Architecture

```text
zcoder.zsh              CLI and curses event loop
lib/
  agent.zsh             Ollama messages and iterative tool loop
  compact.zsh           token accounting and conversation checkpoints
  delegate.zsh          read-only external harness consultations
  instructions.zsh      AGENTS.md discovery, precedence, and prompt assembly
  skills.zsh            standard Agent Skills discovery and progressive loading
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

Turn completion is adaptive across local models. While work remains, the model should call a work tool. When complete or genuinely blocked, it can call `finish` as the only tool with a `complete` or `blocked` status and the final user-facing response. A non-empty tool-free response is also accepted as final because some otherwise tool-capable models do not reliably call `finish` for conversational answers. Empty or malformed responses receive up to three recovery attempts. Tune that budget with `ZCODER_INCOMPLETE_RETRY_LIMIT`; setting it to `0` disables recovery. Set `ZCODER_REQUIRE_FINISH_TOOL=1` to opt into strict structural completion, where every tool-free response is provisional until the model calls `finish`.

## Debugging interrupted turns

Add `--debug` to append structured diagnostics without writing through curses:

```zsh
./zcoder.zsh --debug --model qwen3-coder --workspace /path/to/project
tail -f /tmp/zcoder-debug-${UID}.log
```

The log records session and exit state, Ollama request status, bounded raw responses, parsed content and tool-call counts, recovery or strict-continuation decisions and reasons, and bounded tool-result summaries. Use `--debug-log PATH` or `ZCODER_DEBUG_LOG=PATH` for another location, and `ZCODER_DEBUG_MAX_CHARS` to change the per-record limit. Debug logs can contain prompts, assistant text, and tool arguments, so treat them as sensitive.

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

# Interface and sessions

zcoder's adaptive curses interface keeps the prompt, agent transcript, saved
jobs, project details, and command approvals in one terminal view.

## Layout

The interface includes:

- a header with the model, Ollama host or remote server, workspace, and status
- a sidebar with resumable jobs and the active project/tool policy
- a selectable transcript with foldable messages, tool results, and reasoning
- syntax-highlighted file previews and semantic patch colors
- a multiline editor with a cursor-following viewport and prompt history
- an exact-command approval dialog

At local interactive startup, the status badge reads `[ Warming Up ]` while
zcoder loads the selected Ollama model and submits the stable system/tool
context in the background. You can type immediately. The disposable readiness
exchange is silent and is not part of the saved conversation. The badge changes
to `[ Ready ]` after a successful warm-up.

## Saved sessions

Interactive jobs are stored under `${ZCODER_HOME}/sessions`, normally
`${XDG_CONFIG_HOME:-$HOME/.config}/zcoder/sessions`. Each interactive launch
starts a fresh job. Earlier jobs matching the workspace and profile remain in
the sidebar and can be resumed explicitly. An already-empty latest job is
reused so repeatedly opening and closing zcoder does not accumulate blank
entries.

A session retains:

- Ollama and tool-call history
- the visible transcript, selected entry, and body/reasoning expansion state
- tool identities, arguments, results, and lifecycle state
- context checkpoints and accounting
- active Skills
- the selected model

Sessions are isolated by canonical workspace and prompt profile. A coding
conversation is never offered as a sysadmin session. The session directory is
private to the current user.

Press Tab to focus the sidebar, use Up or Down to choose a job, and press Enter
to return to the prompt. Ctrl+N starts a new job without deleting earlier ones.
`/sessions` focuses the same list.

Remote sessions use the same sidebar controls but remain stored on the named
server. See [Remote-agent server](remote.md).

## Copy the transcript

Continuous curses redraws can make mouse selection unreliable. Ctrl+Y or
`/copy` temporarily leaves the TUI and prints the visible transcript as stable
plain text. Copy it with the terminal's normal controls, then press Enter to
return.

Expanded message bodies, tool results, and reasoning are included. Collapsed
details remain hidden, matching the TUI.

## Inspect and fold transcript entries

Press Tab until the transcript has focus. Up/Down (or k/j) selects an entry;
Home/End selects the first/last entry. Enter or Space expands or collapses its
body. Ctrl+R toggles the selected assistant's reasoning independently. For a
reasoning-only entry, Enter also toggles its reasoning. Tab returns to the prompt.

New tool calls occupy one entry that changes from pending to running and then
completed or failed. Their details start collapsed; expand them to inspect the
arguments and retained result, including read-file and MCP output. File writes
and patches also retain their styled previews. Status text remains readable
without relying on color. Incoming activity preserves a manually scrolled view.

Local sessions retain selection and expansion state. Older saved transcripts
remain readable with their original bodies expanded. An unfinished tool restored
from disk is marked interrupted. Remote connections request structured tool
events and restore saved tool metadata when supported by the server; legacy
servers continue to display their ordinary tool text. Remote expansion changes
remain local to the current view.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Enter | Send the prompt; fold the selected entry when transcript has focus |
| Shift+Enter | Insert a newline; Alt+Enter is the fallback |
| Escape | Stop the active model response, external delegate, or remote turn |
| Tab | Move focus between prompt, sidebar, and transcript |
| Ctrl+O | Open the Ollama model picker |
| Ctrl+R | Toggle selected reasoning in the transcript, otherwise latest reasoning |
| Space | Fold the selected entry when transcript has focus |
| Home / End | Select the first/last entry when transcript has focus |
| Ctrl+N | Start a new saved session |
| Ctrl+Y | Open the plain-text transcript view |
| Page Up / Page Down | Scroll the transcript |
| Ctrl+U | Clear the input |
| Ctrl+W | Delete the previous word |
| Up / Down | Move inside input/history, or select an entry when transcript has focus |
| Ctrl+Q / Ctrl+D | Exit |

## Slash commands

| Command | Action |
| --- | --- |
| `/model` | Open the model picker |
| `/model NAME` | Select a model directly |
| `/host HOST` | Change the Ollama endpoint |
| `/instructions` | List active project instruction sources |
| `/mcp`, `/mcp reload` | Inspect or reload MCP servers |
| `/skills`, `/skills reload` | Inspect or rediscover Skills |
| `/skill NAME` | Activate a Skill |
| `/compact` | Create a context checkpoint |
| `/context` | Show context use and compaction threshold |
| `/goal OBJECTIVE` | Run a persisted goal with independent completion verification |
| `/goal --tokens N OBJECTIVE` | Run a goal with a cumulative model-token limit |
| `/goal`, `/goal status` | Show the saved goal state, attempts, and usage |
| `/goal pause`, `/goal resume`, `/goal clear` | Control the saved goal |
| `/sessions` | Focus saved jobs |
| `/list-agents` | List other live local zcoder instances |
| `/agents` | Show this instance's relay state and queue depth |
| `/agents pause`, `/agents resume` | Reject or resume new incoming handoffs |
| `/copy` | Open the plain-text transcript |
| `/new` | Start a new job |
| `/help` | Show in-app help |
| `/quit` | Exit |

Some controls are intentionally unavailable in remote-client mode because the
server owns that state.

## Persistent goals

A goal continues through tool calls until the worker calls `finish`. Candidate
completion is then checked by a separate read-only model inference. An accepted
candidate ends the goal; a rejected candidate returns its evidence-based
feedback to the worker and the loop continues. The final answer is shown only
after acceptance. A genuine blocker can stop the goal without pretending it
completed.

Goal state follows the saved session. Escape pauses an active local or remote
goal, and an interrupted goal loads as paused after restart. Use `/goal resume`
to continue the same objective, or `/goal clear` to discard it. Remote clients
enable these commands only when the server advertises goal support.

## Local agent handoffs

Interactive zcoder instances owned by the same user on the same machine
publish themselves through a private Unix-socket registry. `/list-agents`
shows each live peer's exact instance ID, project, PID, state, canonical
workspace, profile, and model without starting an Ollama turn.

You can ask the current agent to tell one of those peers about a change or hand
it a focused task. The model discovers the exact target and sends a concise
message only when you explicitly request that communication. An accepted
message is queued by the peer; it does not mean the peer has completed the
work. The receiving terminal renders a distinct Agent relay event and starts
the task in its currently selected session after any active turn finishes.

`/agents pause` rejects new handoffs while retaining messages already accepted;
`/agents resume` begins accepting and processing them again. Discovery and
delivery are not bridged through remote-client mode. See
[Inter-agent communication](inter-agent-communication.md) for protocol and
safety details.

## External harnesses

If their CLIs are installed, zcoder can ask other coding harnesses for a
read-only second opinion:

```text
/claude Review the authentication change for edge cases
/codex Find the likely cause of this failing test
/agy Suggest the smallest safe refactor
/opencode Compare these two implementation approaches
```

Claude uses its read, glob, and grep tools in plan mode. Codex runs in its
read-only sandbox. Antigravity uses plan and sandbox mode. OpenCode uses its plan
agent and a selected `provider/model`; run `/opencode` without a request to open
the picker, or use `/opencode-model PROVIDER/MODEL`.

Add `!` to run the same provider as a coding worker that may edit the selected
workspace:

```text
/claude! Implement the reviewed authentication fix and run focused tests
/codex! Fix the failing parser test
/agy! Apply the smallest safe refactor
/opencode! Implement the selected approach
```

The bang is explicit mutation authority for that invocation. Codex uses its
`workspace-write` sandbox, Claude uses `acceptEdits` with focused coding tools,
Antigravity uses `accept-edits` with terminal sandboxing, and OpenCode uses its
`build` agent without `--auto`. Workers are told to stay inside the workspace
and not install, deploy, commit, push, or publish unless the request explicitly
requires that action. Each bang command starts a fresh harness invocation; it
does not resume an earlier consultation.

Default models and limits:

| Setting | Default |
| --- | --- |
| `ZCODER_CLAUDE_MODEL` | `claude-opus-5` |
| `ZCODER_CODEX_MODEL` | `gpt-5.6-sol` |
| `ZCODER_AGY_MODEL` | `gemini-3.8-flash-high` |
| `ZCODER_OPENCODE_MODEL` | unset; choose in the picker |
| `ZCODER_DELEGATE_TIMEOUT_SECONDS` | 1800 |
| `ZCODER_DELEGATE_MAX_OUTPUT` | 32768 characters |
| `ZCODER_DELEGATE_HISTORY_CHARS` | 12000 characters |
| `ZCODER_DELEGATE_REQUEST_CHARS` | 2000 characters |

`ZCODER_OPENCODE_VARIANT` supplies an optional OpenCode variant. Escape cancels
an active external invocation. Cancelling or timing out a worker does not roll
back edits it already made, so inspect the workspace afterward.

Successful output is decoded from JSON or JSONL and shown in the transcript.
Consultations are retained as explicitly untrusted reference material for later
Ollama turns. Worker reports are retained separately with a warning that the
workspace may have changed and must be inspected before follow-up work.

External harnesses are not invoked through `run_command` and do not use
zcoder's shell-command approval modal. Their own sandbox, tool permissions,
project instructions, and user configuration govern their internal actions.
Use the plain command when you only want advice; use the bang form only when you
intend to authorize workspace changes. Bang commands are disabled in the
`sysadmin` profile because external harness commands cannot participate in its
mandatory per-command approval flow.

zcoder checks `PATH` on the host responsible for the workspace. `/help` reports
which of the four harness commands are available. Invoking a missing plain or
bang command returns the same host-specific message, names the missing binary,
and suggests the installed alternatives. A remote server publishes its own
snapshot during the authenticated handshake, so a workstation does not mistake
its locally installed CLIs for commands present on the server. Older servers
that do not publish this field are reported as availability unknown.

[Documentation index](README.md) · [Configuration](configuration.md) · [Project README](../README.md)

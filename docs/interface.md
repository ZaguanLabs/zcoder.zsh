# Interface and sessions

zcoder's adaptive curses interface keeps the prompt, agent transcript, saved
jobs, project details, and command approvals in one terminal view.

## Layout

The interface includes:

- a header with the model, Ollama host or remote server, workspace, and status
- a sidebar with resumable jobs and the active project/tool policy
- a scrollable transcript with tool activity and collapsible reasoning
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
- the visible transcript and reasoning expansion state
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

Expanded reasoning is included. Collapsed reasoning remains hidden, matching
the TUI.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Enter | Send the prompt |
| Shift+Enter | Insert a newline; Alt+Enter is the fallback |
| Escape | Stop the active model response, consultation, or remote turn |
| Tab | Move focus between prompt, sidebar, and transcript |
| Ctrl+O | Open the Ollama model picker |
| Ctrl+R | Toggle the latest reasoning block |
| Ctrl+N | Start a new saved session |
| Ctrl+Y | Open the plain-text transcript view |
| Page Up / Page Down | Scroll the transcript |
| Ctrl+U | Clear the input |
| Ctrl+W | Delete the previous word |
| Up / Down | Move inside multiline input, then through prompt history |
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
| `/sessions` | Focus saved jobs |
| `/copy` | Open the plain-text transcript |
| `/new` | Start a new job |
| `/help` | Show in-app help |
| `/quit` | Exit |

Some controls are intentionally unavailable in remote-client mode because the
server owns that state.

## External consultants

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

Default models and limits:

| Setting | Default |
| --- | --- |
| `ZCODER_CLAUDE_MODEL` | `claude-opus-5` |
| `ZCODER_CODEX_MODEL` | `gpt-5.6-sol` |
| `ZCODER_AGY_MODEL` | `gemini-3.7-flash-medium` |
| `ZCODER_OPENCODE_MODEL` | unset; choose in the picker |
| `ZCODER_DELEGATE_TIMEOUT_SECONDS` | 1800 |
| `ZCODER_DELEGATE_MAX_OUTPUT` | 32768 characters |
| `ZCODER_DELEGATE_HISTORY_CHARS` | 12000 characters |
| `ZCODER_DELEGATE_REQUEST_CHARS` | 2000 characters |

`ZCODER_OPENCODE_VARIANT` supplies an optional OpenCode variant. Escape cancels
an active consultant and discards its result.

Successful output is decoded from JSON or JSONL, shown in the transcript, and
retained as explicitly untrusted reference material for later Ollama turns. A
consultant is never invoked through `run_command`, never inherits its approval
override, and cannot edit through zcoder.

[Documentation index](README.md) · [Configuration](configuration.md) · [Project README](../README.md)

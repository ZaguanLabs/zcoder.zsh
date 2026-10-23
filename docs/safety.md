# Safety and permissions

zcoder separates workspace file operations from shell execution. This keeps
ordinary code navigation and edits predictable while ensuring arbitrary
commands remain visible to the user.

## Deployment model

zcoder is built for machines and networks you already control: a workstation,
a home lab, or a build server on a private LAN, talking to your own Ollama
host. That focus keeps it small and quick to deploy. Remote workspaces need a
token file rather than a certificate authority, and a server you trust can run
unattended with `--yes`.

The guardrails that protect you on any network stay on in every deployment.
File tools stay inside the workspace. Shell commands ask first unless you chose
otherwise. Project MCP servers start only after you approve them, and the
sysadmin profile approves each command individually. When a workspace must be
reached from a network you do not control, carry the connection through an SSH
tunnel or VPN instead of exposing its port. See
[Network security](remote.md#network-security).

## Workspace boundary

The selected workspace is the boundary for built-in file tools. zcoder
canonicalizes requested paths, resolves symlinks, and rejects anything that
escapes that directory.

Read, search, and edit tools execute directly inside the boundary. This includes
`list_files`, `read_file`, `read_file_range`, `write_file`, `replace_text`,
`apply_patch`, and `search`. Exact replacement requires one unique old-text
match. Tool output returned to the model is bounded to prevent uncontrolled
context growth.

Internal command output, patch, HTTP, delegate, and MCP exchange files live
below one process-private runtime directory. The directory is created
atomically with group and other access disabled, then removed during normal
shutdown. Workspace writes reject dangling symlinks and open the validated
final path without following a last-moment symlink replacement.

Some workspace paths can run code later without passing through command
approval, so the model cannot write them at all: Git metadata (any `.git`
path component, in any letter case) and zcoder's own configuration directory,
`$ZCODER_HOME`, when it lies inside the workspace. `write_file`,
`replace_text`, and the `patch` fallback refuse them, and `git apply` refuses
`.git` paths itself.

`apply_patch` runs `git apply` against a private, empty repository in the
runtime directory, with the workspace as its work tree. Filter drivers,
`fsmonitor`, and other commands defined in the workspace's `.git/config`
therefore never run; your user and system Git configuration still applies.
Patches that create a symbolic link, or change an existing link's target, are
rejected so that a link cannot later expose files outside the workspace.

`read_skill_resource` has a separate read-only boundary. It accepts only
relative paths inside a discovered and activated Skill directory, rejects
escaping symlinks, and cannot write.

## Shell command approval

`run_command` starts in `ask` mode and presents three choices in the coding
profile:

- `y`: allow this exact command once
- `a`: allow commands for the rest of this conversation
- `n` or Escape: deny

An `a` grant belongs to the conversation it was given in. `/new`, switching to
another session, or a different remote session asks again, and restarting the
server clears every grant. Tasks relayed by another local agent still ask for
each command under an `a` grant (see [Local agent relay](#local-agent-relay)).

Commands run with `zsh -c` from the workspace or a workspace-contained `cwd`.
Passing `--yes` selects the allow policy for that coding process. Passing
`--deny-commands` rejects shell commands without prompting.

The approval dialog is designed so that what you approve is what you saw:

- Keys pressed in the first half second after it opens are ignored, so typing
  meant for the prompt cannot answer it.
- When a request is longer than the dialog, the first `y` or `a` scrolls to
  its end; approve after you have seen the whole request.
- Bidirectional-override and zero-width characters, which can reorder or hide
  text, appear as named markers such as `<U+202E>`.

Approval is not a substitute for reading the command. Pay particular attention
to variables, interpreters, downloaded scripts, pipes, and commands that invoke
another shell.

Model, tool, and project text printed directly to a terminal renders control
bytes visibly. This prevents OSC, escape, carriage-return, and backspace data
from changing the apparent approval or transcript display. Redirected output
remains exact for scripting, and persisted transcripts keep their original
content.

## External MCP action confirmation

MCP tools that declare or conservatively appear to perform an externally
visible write require approval for each exact call. This includes actions such
as creating a pull request, posting a message, publishing, or deploying. There
is no session-wide allowance for these actions: `--yes` and
`ZCODER_COMMAND_POLICY=allow` affect shell commands only.

When staged tool exposure is active, external-write MCP tools are also withheld
from the workspace phase. They become visible only after an `external` routing
decision, and dispatch confirmation remains mandatory after that decision.

## External coding workers

The plain `/claude`, `/codex`, `/agy`, and `/opencode` commands are read-only
consultations. Their bang forms, such as `/codex! REQUEST`, explicitly authorize
that external harness to modify the selected workspace for one invocation.

External workers do not call zcoder's `run_command`, so their internal commands
do not pass through zcoder's approval modal or catastrophic-command guard.
Instead they run under the installed harness's own edit mode and permission
policy: Codex uses `workspace-write`, Claude uses `acceptEdits`, Antigravity uses
`accept-edits` with its sandbox, and OpenCode uses `build` without automatic
permission approval. The worker prompt withholds unrelated authority such as
installing, deploying, committing, or pushing unless the request explicitly
requires it.

The harness CLI, its configuration, hooks, plugins, and project instructions
are part of this trust boundary. Review them before using a bang command.
Cancellation, timeout, or a harness error cannot undo changes already made;
inspect `git status` and the workspace before continuing after an interrupted
worker. External workers are disabled entirely in the `sysadmin` profile so
they cannot bypass its mandatory per-command approval policy.

## Local agent relay

Inter-agent delivery is limited to interactive zcoder processes owned by the
same operating-system user on the same machine. The shared registry directory
must be private, real, and user-owned; the message queue remains in the
receiver's process-private runtime directory. There is no TCP, SSH, HTTP, or
remote-client bridge.

The socket listener treats every message as untrusted data. It validates a
bounded frame, target, identifiers, metadata, queue capacity, and task length,
then atomically stores the envelope. It never invokes Ollama, tools, session
code, curses, or shell commands. Only the receiving foreground loop can start
the normal agent turn.

A relayed task is a work request, not evidence about the target workspace. The
receiver must inspect current state, and its own workspace boundary, project
instructions, profile, and `run_command` approval policy remain authoritative.
During a local-user-originated turn, the send tool is available only when that
user explicitly asked to contact another instance. During a relayed turn, it is
scoped to the exact sender instance so the agents can continue a direct
exchange; schema generation and dispatch both block third-agent forwarding.
Each model-requested delivery also requires confirmation for its exact recipient
and message; there is no session-wide inter-agent delivery allowance.
The listener accepts work only from a sender whose instance ID, PID, and
discovery manifest match a live zcoder process, which keeps the displayed
sender truthful and rejects casual forgeries. Processes running as the same
user are not isolated from each other, so this is not authentication: sender
names, PIDs, workspaces, and instance IDs remain context rather than
cryptographic identity. The receiving model is told so, and is not told that
the local user requested the task.

An `a` (allow for this conversation) grant covers your own requests only.
While a relayed task runs, each shell command asks again; answering `a` there
approves just that command. A policy you configured at startup with `--yes`
still applies to relayed tasks.

## Sysadmin profile

The `sysadmin` profile is designed for host maintenance rather than unrestricted
automation:

```sh
./zcoder.zsh --profile sysadmin --model qwen3-coder \
  --workspace /path/to/maintenance-workspace
```

Workspace file tools remain confined to the maintenance directory. Host
inspection and changes must use `run_command`, and every exact command requires
separate approval. Session-wide approval is unavailable; `--yes` and
`ZCODER_COMMAND_POLICY=allow` are rejected.

The sysadmin prompt requires read-only diagnosis, least privilege, small
reviewable changes, rollback planning, configuration validation, secret
redaction, and extra care around storage, networking, SSH, boot,
authentication, and critical services.

A pre-execution guard also rejects unmistakably catastrophic literal commands,
including broad root, system program directory, home (any user's, by path or
`~user`), or workspace deletion; filesystem formatting; raw
block-device writes; device shredding; and storage-pool or logical-volume
destruction. It inspects commands nested in common `sh -c` forms. This is a
conservative guard, not a complete shell security parser.

## Instruction and extension trust

Project instructions and extensions can influence model behavior, so review
them as code:

- `AGENTS.md` may make policy stricter but cannot relax workspace or approval boundaries.
- Skill instructions cannot grant permission through `allowed-tools` metadata.
- Executing a Skill script still requires an approved `run_command`.
- Project `AGENTS.md` files and project Skills that resolve outside the project, for example through a symbolic link, are ignored and listed by `/instructions` or `/skills`.
- Enabling an MCP server exposes its tools without a second per-call approval prompt.
- MCP configuration may contain commands, arguments, environment values, and project overrides.
- A project `.mcp.json` starts nothing until you approve its exact content with `/mcp trust` or `zcoder.zsh mcp trust`. Any later change, including one made by the model, requires approval again.

See [Project guidance and Agent Skills](project-guidance.md) and
[MCP servers](mcp.md) for their complete trust models.

## Remote transport

Remote mode preserves server-side workspace and command policy over
lightweight, token-authenticated HTTP. It is designed for trusted networks.
Reach it through an SSH tunnel or VPN from anywhere else. See the
[remote-agent guide](remote.md#network-security).

[Documentation index](README.md) · [Project README](../README.md)

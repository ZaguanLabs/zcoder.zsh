# Safety and permissions

zcoder separates workspace file operations from shell execution. This keeps
ordinary code navigation and edits predictable while ensuring arbitrary
commands remain visible to the user.

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

`read_skill_resource` has a separate read-only boundary. It accepts only
relative paths inside a discovered and activated Skill directory, rejects
escaping symlinks, and cannot write.

## Shell command approval

`run_command` starts in `ask` mode and presents three choices in the coding
profile:

- `y`: allow this exact command once
- `a`: allow commands for the remainder of the local or remote server process
- `n` or Escape: deny

Commands run with `zsh -c` from the workspace or a workspace-contained `cwd`.
Passing `--yes` selects the allow policy for that coding process. Passing
`--deny-commands` rejects shell commands without prompting.

Approval is not a substitute for reading the command. Pay particular attention
to variables, interpreters, downloaded scripts, pipes, and commands that invoke
another shell.

Model, tool, and project text printed directly to a terminal renders control
bytes visibly. This prevents OSC, escape, carriage-return, and backspace data
from changing the apparent approval or transcript display. Redirected output
remains exact for scripting, and persisted transcripts keep their original
content.

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
Another process already running as the same user can forge same-user metadata,
so sender names, PIDs, workspaces, and instance IDs are context rather than
cryptographic identity.

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
including broad root, home, or workspace deletion; filesystem formatting; raw
block-device writes; device shredding; and storage-pool or logical-volume
destruction. It inspects commands nested in common `sh -c` forms. This is a
conservative guard, not a complete shell security parser.

## Instruction and extension trust

Project instructions and extensions can influence model behavior, so review
them as code:

- `AGENTS.md` may make policy stricter but cannot relax workspace or approval boundaries.
- Skill instructions cannot grant permission through `allowed-tools` metadata.
- Executing a Skill script still requires an approved `run_command`.
- Enabling an MCP server exposes its tools without a second per-call approval prompt.
- MCP configuration may contain commands, arguments, environment values, and project overrides.

See [Project guidance and Agent Skills](project-guidance.md) and
[MCP servers](mcp.md) for their complete trust models.

## Remote transport

Remote mode preserves server-side workspace and command policy, but its native
HTTP transport is not encrypted. Use it only on a trusted network or through a
secure tunnel. See the [remote-agent guide](remote.md).

[Documentation index](README.md) · [Project README](../README.md)

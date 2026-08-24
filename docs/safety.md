# Safety and permissions

zcoder separates workspace file operations from shell execution. This keeps
ordinary code navigation and edits predictable while ensuring arbitrary
commands remain visible to the user.

## Workspace boundary

The selected workspace is the boundary for built-in file tools. zcoder
canonicalizes requested paths, resolves symlinks, and rejects anything that
escapes that directory.

Read, search, and edit tools execute directly inside the boundary. This includes
`list_files`, `read_file`, `read_file_range`, `write_file`, `apply_patch`, and
`search`. Tool output returned to the model is bounded to prevent uncontrolled
context growth.

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

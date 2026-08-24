# Remote-agent server

Remote mode lets you keep the terminal in front of you while the entire zcoder
runtime operates on another machine. The server owns the model connection,
workspace, conversation, project instructions, Skills, MCP processes, and tool
execution. The client sends prompts, renders events, handles approvals, and can
cancel the active turn.

This is different from `--host`, which points a local zcoder process at a remote
Ollama server while keeping tools and workspace access local.

## Create an authentication token

Create the same private token file on both machines. Tokens must contain at
least 32 characters from this URL-safe set:

```text
A-Z a-z 0-9 . _ ~ -
```

A 32-character hexadecimal token contains 128 bits of entropy and meets the
requirement:

```zsh
umask 077
mkdir -p ~/.config/zcoder
openssl rand -hex 16 > ~/.config/zcoder/remote.token
```

For a 256-bit token, use `openssl rand -hex 32`. A 32-bit token is only eight
hexadecimal characters and is both too short and rejected by zcoder.

## Start the server

Run this on the machine that owns the workspace and runs, or can reach, Ollama:

```zsh
./zcoder.zsh \
  --server "Workshop Mac" \
  --port 7337 \
  --token-file ~/.config/zcoder/remote.token \
  --model qwen3-coder \
  --workspace /path/to/project
```

The server runs in the foreground without curses, which makes it suitable for a
terminal multiplexer or service manager. The name identifies the server and its
persistent session. A second process cannot start with the same name and
`ZCODER_HOME` while the first is running.

The server's startup settings are authoritative. In particular:

- `--workspace` selects the only workspace exposed to the agent.
- `--model`, `--host`, and `--profile` control the remote Ollama runtime.
- `--yes` and `--deny-commands` set the server-side command policy.
- the client cannot replace these values after connecting.

## Connect a client

Run this from the machine where you want the TUI:

```zsh
./zcoder.zsh \
  --connect workshop-mac.local:7337 \
  --token-file ~/.config/zcoder/remote.token
```

The default port is 7337, so `--connect workshop-mac.local` is equivalent. An
IPv6 address must be enclosed in brackets.

Remote one-shot prompts work too:

```zsh
./zcoder.zsh \
  --connect workshop-mac.local:7337 \
  --token-file ~/.config/zcoder/remote.token \
  --prompt "Run the tests and explain any failures"
```

## Approvals and cancellation

When `run_command` requires approval, the server pauses its agent worker and
sends the exact command to the client. The local approval dialog answers with a
one-use identifier. A missing, expired, or mismatched response cannot resume
the command.

Choosing “allow session” in the coding profile is remembered for the remainder
of the running server process. The sysadmin profile continues to require
approval for every exact command. If the client does not answer within five
minutes, the command is denied.

Press Escape to ask the server to cancel the active turn. The server terminates
and reaps its worker before accepting another turn.

## Sessions and current limitations

Each named server has one persistent session that survives process restarts.
The first release accepts one active turn at a time. A concurrent turn receives
a busy response instead of running alongside it.

`ZCODER_REMOTE_APPROVAL_TIMEOUT` changes the approval timeout from its default
of 300 seconds. `ZCODER_REMOTE_MAX_REQUEST_BYTES` changes the one-mebibyte
request-body limit.

These controls are not yet exposed remotely:

- session browsing and `/new`
- model or Ollama host switching
- manual `/compact`
- Skills and MCP management screens
- external consultant commands

They fail closed in the client UI. Ordinary prompts, including explicit
`$skill-name` activation, are handled entirely by the remote agent.

## Network security

The native Zsh listener accepts connections on all interfaces. Remote mode uses
authenticated plain HTTP: the bearer token prevents unauthenticated use, but it
does not encrypt the token, prompts, source text, or tool results.

Use it only on a trusted LAN protected by host firewall rules, or carry the
connection through an SSH or VPN tunnel. Do not expose the port directly to the
internet.

[Documentation index](README.md) · [Safety and permissions](safety.md) · [Project README](../README.md)

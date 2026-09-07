# Agent Client Protocol

zcoder can run as an Agent Client Protocol v1 agent over newline-delimited
JSON-RPC stdio. An ACP client such as Zed owns the conversation interface while
zcoder keeps its existing Ollama, session, tool, workspace, Skills, MCP, and
approval machinery.

For exact JSON-RPC flows, supported message shapes, permission handling, and
the contract for a custom harness, read the [ACP protocol integration
reference](acp-integration.md).

This is a protocol adapter, not a second agent implementation. Local ACP turns
enter the same agent loop as the terminal interface. Remote ACP turns cross the
existing authenticated zcoder HTTP API and run in the server's agent loop.

The optional [queued-input extension](queued-input.md#acp-extension) lets clients
send steering or follow-ups while a prompt runs. It uses `_zcoder/input`;
standard `session/prompt` remains single-flight. The extension is also available
over `--connect` when the remote server advertises queue support.

## Direct local use

Start the stdio agent with:

```zsh
./zcoder.zsh --acp --model qwen3-coder
```

The ACP client's `session/new` request selects the workspace, so a fixed
`--workspace` is usually unnecessary. It remains useful for clients that launch
the process from an unrelated directory.

For example, add zcoder as a custom External Agent in Zed's settings, using an
absolute command path:

```json
{
  "agent_servers": {
    "zcoder": {
      "type": "custom",
      "command": "/absolute/path/to/zcoder.zsh/zcoder.zsh",
      "args": ["--acp", "--model", "qwen3-coder"],
      "env": {}
    }
  }
}
```

Zed's `dev: open acp logs` command is useful when inspecting the JSON-RPC
exchange.

## ACP backed by a remote zcoder server

Run the existing remote server beside the authoritative model and workspace:

```zsh
./zcoder.zsh \
  --server workshop \
  --port 7337 \
  --token-file ~/.config/zcoder/remote.token \
  --model qwen3-coder \
  --workspace /srv/projects/example
```

Configure the ACP client machine to launch this adapter command:

```zsh
./zcoder.zsh \
  --acp \
  --connect workshop.example:7337 \
  --token-file ~/.config/zcoder/remote.token
```

In Zed, put those arguments in the custom agent's `args` array. The small local
process speaks ACP over stdio and translates turns, session operations, tool
events, cancellation, and approval decisions to the authenticated remote API.
All model calls and tools execute on the server.

The ACP client's path and the server workspace path may differ. The server's
configured workspace is authoritative; this is what makes the adapter usable
across systems without pretending that their filesystems are shared. Embedded
text context sent in a prompt still reaches the remote agent.

Remote mode uses authenticated plain HTTP. Use a trusted LAN, firewall rules,
or an SSH or VPN tunnel, as described in the [remote-agent guide](remote.md).

## Implemented ACP surface

- protocol v1 initialization and capability negotiation
- `session/new`, `session/load`, `session/prompt`, and `session/cancel`
- persistent zcoder sessions and history replay during `session/load`
- text, resource links, and embedded text resources in prompts
- agent message and reasoning updates
- pending, running, completed, and failed tool-call updates
- client permission requests for commands and external actions
- one-turn and coding-session command approval
- stdio MCP servers forwarded by the ACP client in direct local mode

zcoder advertises only what it implements. It does not advertise image or audio
prompts, client filesystem delegation, client terminal delegation, session
modes, or authentication methods. Its own confined tools remain authoritative,
and `run_command` continues through the normal approval policy.

ACP-forwarded MCP servers cannot currently cross the zcoder remote protocol.
Configure those MCP servers on the remote zcoder host instead. Direct local ACP
mode accepts forwarded stdio MCP servers normally.

## Process and transport behavior

Protocol messages use stdout exclusively; diagnostics go to stderr. A prompt
runs in a Zsh coprocess so the foreground broker can continue reading
cancellation and permission responses. Only one prompt may run at a time, and
session creation or loading is rejected until that prompt completes.

Remote tool lifecycle events are requested explicitly by the ACP adapter. The
field is optional on the HTTP turn request, so existing protocol-1 TUI clients
retain their previous event stream and remain compatible.

[Remote-agent guide](remote.md) · [Architecture](architecture.md) ·
[Project README](../README.md)

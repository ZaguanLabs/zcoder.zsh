# MCP servers

zcoder implements the MCP tools client subset over stdio. Enabled tools become
part of the Ollama tool catalog and their results return through normal agent
history.

## Protocol support

The client supports protocol versions `2025-11-25` and `2026-07-28`. It sends a
modern `server/discover` probe first. A 2026 server receives namespaced client
metadata on every request; a legacy server falls back to `initialize` and
`notifications/initialized`.

Tool listing follows pagination, input schemas pass through to Ollama, nested
arguments are preserved, and tool results remain in conversation history. Tool
names use the form `mcp__SERVER__TOOL`, with punctuation normalized to
underscores. The system prompt includes a bounded mapping from short names to
these namespaced functions so project instructions can route smaller models
reliably.

Project-designated MCP routing takes precedence over the default built-in
search workflow.

## Configuration

User servers live in `${ZCODER_HOME}/mcp.json`. Project servers live in
`<workspace>/.mcp.json` and override same-named user definitions.

Both use the common `mcpServers` shape:

```json
{
  "mcpServers": {
    "project-index": {
      "type": "stdio",
      "command": "example-mcp-server",
      "args": ["--stdio"],
      "env": {"EXAMPLE_MODE": "local"},
      "enabled": true
    }
  }
}
```

## CLI management

Registry commands do not require Ollama:

```sh
./zcoder.zsh mcp list
./zcoder.zsh mcp list --json
./zcoder.zsh mcp get project-index --json
./zcoder.zsh mcp add project-index -- example-mcp-server --stdio
./zcoder.zsh mcp add --scope project --env EXAMPLE_MODE=local \
  project-index -- example-mcp-server --stdio
./zcoder.zsh mcp disable project-index
./zcoder.zsh mcp enable project-index
./zcoder.zsh mcp test project-index
./zcoder.zsh mcp remove project-index
```

`delete` is an alias for `remove`. New servers default to user scope; pass
`--scope project` to write `.mcp.json`. Enable, disable, and remove operate on
the visible definition unless a scope is explicit.

`list` reports configuration without launching servers. `test` negotiates the
protocol and discovers tools.

## TUI management

`/mcp` opens a live status modal and connects enabled servers. Press `r` to
restart the selected server. `/mcp reload` rereads user and project
configuration. Normal startup remains fast because MCP processes start lazily
when their tools are first needed.

## Trust boundary

Adding and enabling a server admits its catalog, but selecting a tool is not
authority to create an externally visible side effect. zcoder classifies each
MCP tool from the standard `readOnlyHint`, `openWorldHint`, and
`destructiveHint` annotations. For older servers without annotations, clearly
read-shaped tool names remain read-only and unknown capabilities fail toward
the externally mutating class.

Read-only and explicitly local workspace tools execute under the server trust
boundary. Tools classified as `external_write` require confirmation for every
call, even when shell commands have been allowed for the session. In staged
exposure, those tools are absent from the workspace phase and appear only after
the router identifies an explicitly requested external action. This does not
change `run_command`: shell commands retain their separate approval policy.

Review server commands, arguments, environment values, and project `.mcp.json`
before enabling them.

The current implementation is stdio-first. Streamable HTTP, OAuth, prompts,
resources, sampling, and elicitation are not exposed. Configured non-stdio
servers remain visible with an `unsupported` status.

[Documentation index](README.md) · [Safety and permissions](safety.md) · [Project README](../README.md)

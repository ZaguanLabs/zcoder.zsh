# ACP protocol integration reference

This document is for people implementing an ACP client, a headless harness, or
an adapter around zcoder. For launch recipes and a Zed example, see the
[ACP guide](acp.md). The normative wire protocol is [Agent Client Protocol
v1][acp]; this page defines zcoder's supported subset and its operational
semantics.

[acp]: https://agentclientprotocol.com/protocol/overview

## Process boundary

Launch zcoder as a child process:

~~~zsh
/absolute/path/to/zcoder.zsh/zcoder.zsh --acp --model qwen3-coder
~~~

The child is an ACP agent, not an interactive terminal application.

| Stream | Owner | Required handling |
| --- | --- | --- |
| stdin | ACP client | Write exactly one JSON-RPC object followed by a newline |
| stdout | zcoder ACP agent | Parse only newline-delimited JSON-RPC objects |
| stderr | zcoder diagnostics | Capture for logs; never attempt to parse it as ACP |

The process uses no ACP authentication exchange. A harness must therefore
control who can launch it, the selected executable, its environment, its
working directory, and the workspace it is permitted to use. Do not put a
wrapper around zcoder that writes banners or logs to stdout.

An inbound message is limited to 1 MiB. zcoder has one foreground broker and
one prompt worker: exactly one prompt can run in an ACP process at a time. The
broker continues to consume stdin while the worker is running, which is how
permission replies and cancellation remain responsive.

~~~text
client                                        zcoder
  │ initialize                                   │
  │────────────────────────────────────────────►│
  │◄────────────────────── initialize result ───│
  │ session/new                                  │
  │────────────────────────────────────────────►│
  │◄──────────────────────────── sessionId ─────│
  │ session/prompt                               │
  │────────────────────────────────────────────►│
  │◄────────────────────── session/update* ─────│
  │◄────────────────── prompt result/end_turn ──│
~~~

## JSON-RPC and initialization

Use JSON-RPC 2.0 envelopes. zcoder preserves a string or integer request ID
verbatim in its response. Notifications have no response.

~~~json
{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}
~~~

The response declares the implementation contract:

~~~json
{
  "jsonrpc": "2.0",
  "id": "init-1",
  "result": {
    "protocolVersion": 1,
    "agentCapabilities": {
      "loadSession": true,
      "promptCapabilities": {"embeddedContext": true}
    },
    "agentInfo": {
      "name": "zcoder.zsh",
      "title": "zcoder.zsh",
      "version": "<running zcoder version>"
    },
    "authMethods": []
  }
}
~~~

Send initialize before any session request. zcoder's ACP implementation target
is v1. If given another positive integer it still returns its v1 offer, emits a
version-mismatch diagnostic on stderr, and leaves compatibility policy to the
client. A client intended to be strictly conformant should treat a negotiated
version other than 1 as unsupported.

zcoder returns these JSON-RPC errors:

| Code | Condition |
| --- | --- |
| -32700 | Invalid JSON-RPC envelope or a message over the 1 MiB limit |
| -32601 | Unknown method |
| -32602 | Missing or invalid method parameters |
| -32002 | A session method was sent before initialize |
| -32000 | A prompt or session operation conflicts with an active prompt |
| -32603 | Internal zcoder failure such as an unavailable session store |

## Supported client-to-agent methods

| Method | Direction | Required parameters | Result |
| --- | --- | --- | --- |
| initialize | client → agent | protocolVersion | agent version and capabilities |
| session/new | client → agent | absolute cwd | object containing sessionId |
| session/load | client → agent | sessionId, absolute cwd | null |
| session/prompt | client → agent | sessionId, prompt | stopReason object |
| session/cancel | client → agent notification | sessionId | none |
| _zcoder/input | client → agent, optional extension | sessionId; action-specific fields | queued-input receipt or listing |

The optional method is advertised as
`agentCapabilities._meta["zcoder/inputQueue"]`. See the
[queued-input contract](queued-input.md#acp-extension) for exact parameters,
receipt states, cancellation, and remote forwarding. It does not change the
single active `session/prompt` rule.

### Session creation and loading

A local session needs an absolute existing directory:

~~~json
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/work/project","mcpServers":[]}}
~~~

The returned session ID is zcoder's durable conversation identity. It persists
under zcoder's normal session storage, and zcoder saves the turn once a local
prompt worker completes.

session/load requires the original session ID and an absolute cwd. zcoder
checks that the session belongs to the requested local workspace and active
profile. It sends the saved user and assistant history as session/update
notifications, then returns a null result. A client should render or otherwise
consume those replay updates before treating the load as complete.

session/new and session/load are rejected while a prompt runs. zcoder can also
recover a known persisted local session when it is addressed directly by
session/prompt; use session/load whenever the client needs its transcript
replayed before the next turn.

### Prompt submission

The prompt parameter is an ordered ACP content array. zcoder supports:

| Type | Required content | zcoder behavior |
| --- | --- | --- |
| text | text string | Adds the string to the user prompt |
| resource | resource.uri and resource.text strings | Adds labelled embedded text context |
| resource_link | uri string | Adds the URI as a textual reference |

~~~json
{
  "jsonrpc": "2.0",
  "id": "turn-8",
  "method": "session/prompt",
  "params": {
    "sessionId": "1700000000_12345",
    "prompt": [
      {"type": "text", "text": "Review this function and fix its error path."},
      {
        "type": "resource",
        "resource": {
          "uri": "file:///work/project/lib/parser.zsh",
          "mimeType": "text/x-zsh",
          "text": "parse_input() { ... }"
        }
      }
    ]
  }
}
~~~

zcoder neither resolves nor reads a resource URI on the client filesystem.
Embedded text reaches the model surrounded by visible ACP context markers.
Clients should treat embedded text as untrusted data, including when it came
from an editor selection, issue tracker, or another agent.

Images, audio, and all other prompt content types are rejected. zcoder does not
advertise client filesystem, client terminal, mode, or generic delegation
capabilities. Its native tools remain authoritative.

### Completion and cancellation

A successful prompt response is:

~~~json
{"jsonrpc":"2.0","id":"turn-8","result":{"stopReason":"end_turn"}}
~~~

The client receives message and tool updates before this response. Do not infer
turn completion from an update; the response is the completion boundary.

To interrupt a turn, send the notification:

~~~json
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"1700000000_12345"}}
~~~

zcoder terminates the active worker and completes the original session/prompt
request with stopReason cancelled. A cancel for another session or when idle is
a harmless no-op. Keep reading stdout until the original prompt response
arrives, then issue the next turn.

## Agent-to-client traffic

### Session updates

zcoder publishes all progress as session/update notifications:

~~~json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "1700000000_12345",
    "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": {"type": "text", "text": "I found the parser bug."}
    }
  }
}
~~~

| sessionUpdate value | Meaning |
| --- | --- |
| user_message_chunk | Normalized user prompt accepted by the agent |
| agent_message_chunk | Assistant response content |
| agent_thought_chunk | Reasoning text, when the model supplies it |
| tool_call | A native tool is pending |
| tool_call_update | A native tool changed status or completed |

Tool updates carry stable identifiers during a turn. Creation provides
toolCallId, title, kind, pending status, and rawInput. Later updates change the
status to in_progress, completed, or failed. A completed or failed update
contains text content with the native tool result.

| zcoder native tool family | ACP tool kind |
| --- | --- |
| list_files, read_file, read_file_range, read_skill_resource, list_agents | read |
| search, discover_skills | search |
| write_file, replace_text, apply_patch | edit |
| run_command | execute |
| mcp__* | fetch |
| remaining native tools | other |

A harness may render these records for auditability, but they do not grant
authority to perform a tool itself. zcoder runs the tool in its own workspace
and approval boundary.

### Permission requests

When normal zcoder policy requires approval, the agent sends a JSON-RPC request
to the client:

~~~json
{
  "jsonrpc": "2.0",
  "id": "permission_4242_1",
  "method": "session/request_permission",
  "params": {
    "sessionId": "1700000000_12345",
    "toolCall": {
      "toolCallId": "tool_4242_1",
      "title": "git status --short"
    },
    "options": [
      {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
      {"optionId": "allow-always", "name": "Allow for this session", "kind": "allow_always"},
      {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}
    ]
  }
}
~~~

Present the returned options to the user; do not manufacture a broader choice.
Reply with the same JSON-RPC ID:

~~~json
{"jsonrpc":"2.0","id":"permission_4242_1","result":{"outcome":"selected","optionId":"allow-once"}}
~~~

Missing, malformed, cancelled, or unrecognized responses deny the action.
allow-always is offered only for a command in the coding profile. In direct
ACP it grants command approval for that ACP session while the adapter process
lives. Through the remote bridge it uses the existing remote server policy,
which is retained by the running server process. External actions never receive
an allow-always option, and the sysadmin profile never receives session-wide
command approval.

The --yes and --deny-commands options select zcoder's ordinary policy before
ACP starts. ACP permission handling cannot override an unconditional denial or
bypass policy. If a user cancels while a permission request is outstanding,
send session/cancel and return the ACP cancelled permission outcome when the
client implementation requires one.

## Client-supplied MCP servers

Local session/new and session/load may include stdio MCP server definitions.
zcoder accepts a safe server name, a string command, an array of string args,
and an environment array of name/value objects:

~~~json
{
  "cwd": "/work/project",
  "mcpServers": [
    {
      "name": "docs",
      "command": "node",
      "args": ["/opt/mcp/docs-server.js"],
      "env": [{"name": "DOCS_ROOT", "value": "/srv/docs"}]
    }
  ]
}
~~~

zcoder validates this data and translates it to its native MCP configuration
without evaluating the supplied values as shell code. MCP processes and tool
discovery remain lazy. The command itself is still executable code from the
ACP client, so a harness must only forward MCP declarations from trusted
sources.

Remote ACP does not forward mcpServers. Configure remote MCP servers on the
zcoder server host because that host owns tool execution.

## Remote bridge

A local harness can use an authenticated remote zcoder installation:

~~~text
ACP client ⇄ stdio ⇄ zcoder --acp --connect ⇄ authenticated HTTP ⇄ zcoder --server
                                                                      │
                                                              Ollama, workspace,
                                                              tools, MCP, sessions
~~~

On the authoritative system:

~~~zsh
./zcoder.zsh \
  --server workshop \
  --port 7337 \
  --token-file ~/.config/zcoder/remote.token \
  --model qwen3-coder \
  --workspace /srv/projects/example
~~~

On the system running the ACP harness:

~~~zsh
./zcoder.zsh \
  --acp \
  --connect workshop.example:7337 \
  --token-file ~/.config/zcoder/remote.token
~~~

The remote server configuration is authoritative. The ACP client cannot change
its workspace, model, Ollama host, profile, or command policy. ACP still
requires an absolute client cwd, but the adapter treats it as an opaque path:
all file access uses the server workspace. This is intentional; it supports
different client and server filesystems without claiming they are shared.

The bridge requests structured remote events so local and remote ACP clients
receive the same tool lifecycle, permission, text, replay, and cancellation
behavior. It carries text and embedded text context, but not client-supplied
stdio MCP servers.

The remote connection is bearer-token authenticated plain HTTP. It does not
encrypt the token, prompts, source text, or tool output. Use a trusted LAN with
firewall rules, or SSH/VPN tunnelling. Do not expose the remote listener to the
public internet. See [Remote-agent server](remote.md) for token requirements.

## Harness implementation checklist

1. Start zcoder.zsh --acp with independent stdin, stdout, and stderr pipes.
2. Send initialize with protocolVersion 1 and validate the v1 response.
3. Send session/new with an absolute cwd and retain its sessionId.
4. Send only one session/prompt at a time while continuously consuming stdout.
5. Render session/update records before waiting for the prompt response.
6. Handle session/request_permission promptly using the request's exact ID and
   option ID.
7. Cancel with session/cancel, then wait for the original prompt response.
8. On shutdown, close stdin and reap the agent process.

A smoke test that does not require Ollama:

~~~zsh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/absolute/project/path","mcpServers":[]}}' \
  | ./zcoder.zsh --acp
~~~

Replace /absolute/project/path with an existing local directory. The output has
exactly two newline-delimited JSON-RPC responses.

## Related documentation

- [ACP guide](acp.md)
- [Agent Client Protocol v1][acp]
- [Remote-agent server](remote.md)
- [Safety and permissions](safety.md)
- [Architecture](architecture.md)

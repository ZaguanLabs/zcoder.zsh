# Remote access system API and reimplementation specification

- Status: implementation-derived specification
- Protocol: zcoder remote protocol 1
- Source baseline: zcoder.zsh 0.9.3
- Last reviewed: 2026-08-31

This document specifies the remote-agent system implemented by zcoder.zsh in
enough detail to build a different client, a different server, a protocol
gateway, or a replacement transport. It covers the wire API, state ownership,
model readiness, turn execution, event delivery, approvals, cancellation,
session persistence, security boundaries, failure behavior, and the supporting
services needed for a complete implementation.

The existing [remote-agent guide](remote.md) is the operator-facing setup guide.
This document is the engineering contract. Where it describes an exact current
behavior, that behavior comes from `lib/remote.zsh` and its integration points.
Where it recommends a stronger design, the recommendation is explicitly marked
as a hardened replacement requirement rather than protocol-1 behavior.

## 1. Purpose and implementation targets

There are two useful ways to apply this specification.

### 1.1 Wire-compatible implementation

A wire-compatible implementation can replace one side of an existing zcoder
connection:

- an alternative client can control the existing zcoder server;
- an alternative server can be controlled by the existing zcoder client;
- a gateway can present protocol 1 on one side and another transport or agent
  runtime on the other.

For this target, endpoint paths, flat JSON envelopes, cursor behavior,
authentication, response status codes, and polling semantics are compatibility
requirements. Sections marked **Protocol-1 requirement** are normative.

### 1.2 Semantic replacement

A semantic replacement can use HTTPS, WebSocket, SSH, QUIC, a message broker,
or another API while preserving the remote-agent behavior:

- the server owns the workspace and agent runtime;
- the client presents prompts, events, approvals, and cancellation;
- one active turn is serialized per server identity;
- approvals never bypass the server's command policy;
- session state remains authoritative on the server;
- cancellation stops and reaps the execution worker;
- all file and tool operations obey the server's workspace boundary.

For this target, the API can change, but the state machines and trust boundaries
in this document should remain explicit. A compatibility adapter can translate
the replacement protocol back to protocol 1 if existing zcoder clients must
continue to work.

## 2. Scope and non-goals

The remote-agent system moves the complete coding-agent runtime to another
machine. It is not merely a remote model endpoint.

The server owns:

- the Ollama connection and configured model;
- the canonical workspace;
- project instructions and discovered Agent Skills;
- MCP processes and their tools;
- the complete model/tool conversation;
- visible transcript persistence;
- context sizing and compaction;
- all built-in file operations and patches;
- shell execution and its approval policy;
- session selection and session creation;
- model warm-up and readiness checks;
- the active worker process and its cancellation.

The client owns:

- interactive or one-shot prompt entry;
- display of server-authored messages, reasoning, tool results, and statuses;
- the local approval dialog for commands that the server asks to run;
- the user's cancellation gesture;
- an in-memory view of the server's session list and selected transcript.

The client does not receive a general remote filesystem API. It does not run
the server's tools locally and does not keep a second durable copy of the
server's conversation.

The following systems are separate and must not be conflated with this API:

- `--host` points a local zcoder process at an Ollama server. The agent, tools,
  workspace, instructions, and approvals remain local.
- The local inter-agent relay in `lib/relay.zsh` uses private Unix-domain
  sockets and `ZCODER-AGENT/1` length-prefixed frames. It transfers tasks
  between same-user local TUI processes. It is not exposed through the remote
  HTTP API.
- External harness commands such as Claude, Codex, Antigravity, and OpenCode
  are only advertised as availability metadata. Protocol 1 does not expose a
  remote endpoint to invoke them.

## 3. System model

```text
┌──────────────────────── client machine ────────────────────────┐
│ prompt/UI or one-shot client                                   │
│  - handshake and capability cache                              │
│  - model-status polling                                        │
│  - event cursor and renderer                                   │
│  - approval dialog                                             │
│  - cancellation control                                        │
└──────────────────────────────┬─────────────────────────────────┘
                               │ authenticated HTTP/1.1
                               │ one request per TCP connection
┌──────────────────────────────▼─────────────────────────────────┐
│ named remote-agent server                                      │
│  listener/router  ───── private runtime/event rendezvous       │
│       │                         │                               │
│       │ spawn                   │ poll/write                    │
│       ▼                         ▼                               │
│  one turn worker ───── approval rendezvous                     │
│       │                                                         │
│       ├── persistent sessions                                  │
│       ├── project instructions, Skills, MCP                    │
│       ├── workspace-confined tools and command policy          │
│       └── Ollama model API                                     │
└──────────────────────── server machine ────────────────────────┘
```

The listener is long-lived. A turn executes in a background Zsh child so the
listener can continue to serve event polling, approval responses, and
cancellation while the agent is working. The warm-up request also runs in a
background child. Those children close inherited listener and accepted-client
descriptors before connecting to Ollama; otherwise the client could wait
forever for `Connection: close` while a descendant still owns the descriptor.

### 3.1 Authority table

| Decision or state | Authority | Client may override it? |
| --- | --- | --- |
| Workspace | Server startup | No |
| Ollama host | Server startup | No |
| Model | Server startup or saved server session | No remote model-selection endpoint |
| Profile | Server startup | No |
| Initial command policy | Server startup | No |
| Coding session-wide command approval | Server process after an `a` decision | Yes, only through the approval flow |
| Sysadmin per-command approval | Server profile | No session-wide override |
| Conversation and transcript | Server session store | No durable client copy |
| Current session | Named server | Yes, through session endpoints while idle |
| Model readiness | Server's Ollama adapter | Client can request a check, not set the result |
| Turn cancellation | Server process | Client can request it |

## 4. Runtime and deployment requirements

### 4.1 Existing zcoder server

The current server requires:

- Zsh 5.8 or newer;
- the loadable modules `zsh/datetime`, `zsh/files`, `zsh/mapfile`,
  `zsh/net/tcp`, `zsh/system`, and `zsh/zselect`;
- a reachable Ollama HTTP endpoint;
- a tool-capable configured model;
- a readable canonical workspace;
- writable private storage below `ZCODER_HOME`;
- a TCP port, 7337 by default;
- a private shared-token file;
- network policy that limits the unencrypted listener to trusted paths.

The server runs in the foreground and does not initialize curses. It listens on
all interfaces supported by `ztcp -l`; interface selection is not part of the
current CLI.

### 4.2 Existing zcoder client

The current client requires:

- the same minimum Zsh and core modules;
- `zsh/curses` and `zsh/terminfo` for interactive mode;
- TCP reachability to the server or to a local tunnel endpoint;
- a token file containing the same bearer token as the server;
- a terminal for interactive mode, or `--prompt` for one-shot mode.

The client does not need Ollama, the remote workspace, the remote MCP programs,
or the server's external harnesses installed locally.

### 4.3 Starting the current implementation

Server:

```zsh
./zcoder.zsh \
  --server "Workshop Mac" \
  --port 7337 \
  --token-file ~/.config/zcoder/remote.token \
  --model qwen3-coder \
  --workspace /srv/projects/example
```

Client:

```zsh
./zcoder.zsh \
  --connect workshop-mac.local:7337 \
  --token-file ~/.config/zcoder/remote.token
```

The endpoint accepts `hostname`, `hostname:port`, `http://hostname:port`, an
enclosed IPv6 literal such as `[2001:db8::1]`, or an enclosed literal with a
port. The default client port is 7337. The current client rejects `https://`
and rejects an unenclosed IPv6 literal.

### 4.4 Named-server identity and storage

The server name is both display metadata and the key for persistent server
state. The current implementation converts every character outside
`A-Z`, `a-z`, `0-9`, `_`, `.`, and `-` to `_`, then uses:

```text
${ZCODER_HOME}/remote/<safe-server-name>/
```

Two distinct names that sanitize to the same value collide. A replacement
should either preserve this mapping for compatibility or use a collision-free
identifier and keep the display name separate.

The current runtime contains:

```text
remote/<safe-server-name>/
  server.pid
  selected_session
  command_policy
  active.pid                 # present while a turn worker is active
  pending_prompt             # present while a prompt waits for warm-up
  pending_approval           # one-use approval ID
  worker.done
  events/
    000000001.json
    000000002.json
    ...
  approvals/
    <approval-id>.response
  sessions/
    <epoch>_<random>.session/
      ... normal zcoder session files ...
```

The server creates the runtime, event, and approval directories under a 077
umask and attempts to enforce mode 0700. It uses `server.pid` to reject a
second live server with the same sanitized name. Session data survives normal
server restarts. Per-turn events, active markers, pending prompts, and pending
approvals are transient.

A hardened implementation should use an exclusive lock or lease tied to the
actual process instance rather than trusting `kill -0` and a reusable PID.

## 5. Authentication and transport

### 5.1 Bearer token

**Protocol-1 requirement:** every endpoint, including `/v1/hello`, requires:

```http
Authorization: Bearer <token>
```

The current server performs an exact comparison of the complete header value
with `Bearer ${REMOTE_TOKEN}`. Header names are treated case-insensitively by
the HTTP parser; the scheme and spacing in the value must match exactly.

The token-file contract is:

- the path is required in server and client modes;
- the resolved target must be a readable regular file;
- it must be owned by the invoking effective user;
- no group or other permission bits may be set;
- mode 0600, 0400, or stricter is accepted;
- trailing CR and LF characters are removed;
- the remaining token must contain at least 32 characters;
- every character must be in `A-Z a-z 0-9 . _ ~ -`;
- there is no unauthenticated mode.

The token is a server-wide capability. Protocol 1 has no users, roles, token
rotation endpoint, scopes, expiration, request signature, nonce, or replay
protection. Anyone holding it has all protocol permissions, including reading
transcripts, submitting prompts, approving commands, switching sessions, and
cancelling work.

### 5.2 HTTP profile

**Protocol-1 requirement:** the native transport is HTTP/1.1 over plain TCP.
The current server processes one request per accepted connection and always
closes the connection after one response.

Clients should send:

```http
POST /v1/example HTTP/1.1
Host: server.example:7337
Authorization: Bearer <token>
Content-Type: application/json
Accept: application/json
Connection: close
Content-Length: <decimal byte count>

<JSON body>
```

Important compatibility details:

- Request targets use origin form and are matched as literal strings.
- Methods are uppercase `GET` or `POST`.
- `Content-Length` is the JSON body length in bytes, not characters.
- A missing `Content-Length` is treated as zero by the current server. Clients
  must send it; a hardened replacement should require it on body-bearing
  methods.
- GET requests from the native client still send `Content-Length: 0` and an
  empty body.
- Chunked request bodies are not decoded by the current server. Without a
  `Content-Length`, the endpoint sees an empty body.
- Persistent connections and pipelining are not supported.
- The server does not require or inspect the request `Content-Type`, but a
  compatible client should send `application/json`.
- The server accepts only the query layouts documented below; it does not run a
  general URL decoder or query-parameter parser.

The current server limits the complete request header to 65,536 bytes and the
body to `ZCODER_REMOTE_MAX_REQUEST_BYTES`, 1,048,576 bytes by default. Header
and body reads use a 10-second timeout for each blocking read operation.

Every server response includes:

```http
Content-Type: application/json
Cache-Control: no-store
Connection: close
Content-Length: <decimal byte count>
```

The native client accepts any HTTP status in the 2xx class. It can decode
`Content-Length` or chunked responses, although the native server always emits
`Content-Length` and closes the connection.

### 5.3 JSON profile

**Protocol-1 requirement:** request and response envelopes are JSON objects.
The protocol deliberately uses flat objects: every top-level value is a
string, number, boolean, or null. Nested objects and arrays are not part of the
protocol-1 endpoint schemas.

Strings can contain JSON escapes, Unicode escapes, newlines, tabs, quotes, and
backslashes. A new implementation should encode JSON as UTF-8 and calculate
HTTP lengths from the encoded bytes. The current implementation does not
advertise a charset and relies on the process locale for character handling.

Unknown scalar fields should be ignored for forward compatibility. A strict
implementation may reject nested unknown values because the current native
flat-object parser cannot consume them.

### 5.4 Error envelope and status codes

Every route error uses:

```json
{"error":"human-readable explanation"}
```

The server can return:

| HTTP status | Meaning |
| ---: | --- |
| 200 | Successful synchronous request |
| 202 | Turn accepted or queued |
| 400 | Malformed HTTP, invalid JSON, invalid field, or invalid cursor |
| 401 | Missing or incorrect bearer token |
| 404 | Unknown endpoint or inaccessible/nonexistent session |
| 409 | State conflict: busy turn, stale approval, no cancellable turn |
| 413 | Header or body exceeds the configured bound |
| 500 | Server could not publish or initialize required state |
| 503 | Model preparation failed before turn start |

Protocol 1 does not use a distinct 405 response; an unsupported method/path
combination falls through to 404.

## 6. API summary

| Method | Path | Purpose | Normal status |
| --- | --- | --- | ---: |
| GET | `/v1/hello` | Handshake, server authority, capabilities, initial readiness check | 200 |
| GET | `/v1/model` | Poll an already-running model warm-up | 200 |
| POST | `/v1/model/ensure` | Recheck configured-model residency and start warm-up if needed | 200 |
| POST | `/v1/turn` | Start one agent turn or queue it behind warm-up | 202 |
| GET | `/v1/events?after=N` | Return the first current-turn event with sequence greater than `N` | 200 |
| GET | `/v1/sessions?after=N` | Return session-list item `N + 1` | 200 |
| GET | `/v1/session?id=ID&after=N` | Return transcript item `N + 1` for one session | 200 |
| POST | `/v1/session/select` | Select a server-owned session | 200 |
| POST | `/v1/session/new` | Create and select an empty session | 200 |
| POST | `/v1/approval` | Answer the current one-use command approval | 200 |
| POST | `/v1/cancel` | Cancel a queued prompt or active worker | 200 |

All routes share one named-server state. There is no client ID, connection
session, cookie, or turn namespace in protocol 1.

## 7. Handshake: `GET /v1/hello`

### 7.1 Behavior

The handshake authenticates the client, performs a forced readiness check for
the server's configured model, and returns the server-authored operating
context. Starting the server alone does not warm the model; the first handshake
is a meaningful readiness boundary.

Example response:

```json
{
  "protocol": 1,
  "server_name": "Workshop Mac",
  "workspace": "/srv/projects/example",
  "model": "qwen3-coder:latest",
  "profile": "coding",
  "command_policy": "ask",
  "model_status": "warming",
  "model_error": "",
  "harnesses": "claude,codex",
  "sessions": true
}
```

The actual response is compact JSON on one line. Whitespace shown in examples
is non-normative.

### 7.2 Response fields

| Field | Type | Meaning |
| --- | --- | --- |
| `protocol` | number | Must be `1`; the current client rejects any other or missing value |
| `server_name` | string | Display name configured with `--server` |
| `workspace` | string | Canonical server-side workspace; informational to the client and authoritative for tools |
| `model` | string | Server-selected Ollama model |
| `profile` | string | Normally `coding` or `sysadmin` |
| `command_policy` | string | Effective `ask`, `allow`, or `deny` policy |
| `model_status` | string | `ready`, `warming`, or `error` after the handshake check |
| `model_error` | string | Empty unless model preparation failed |
| `harnesses` | string | Comma-separated installed server commands from `claude,codex,agy,opencode` |
| `sessions` | boolean | `true` when session endpoints are supported |

The client replaces its local workspace, model, profile, and command-policy
display state with these values. Local CLI values do not override them.

### 7.3 Backward compatibility

Early protocol-1 servers omitted later capability fields. The current client
uses these rules:

- missing `model_status` means `unmanaged`; the client skips readiness
  endpoints and lets the first real turn load the model;
- missing `harnesses` means availability is unknown, not that every harness is
  unavailable;
- `harnesses` is recognized only when its JSON type is string;
- missing or non-true `sessions` disables remote session browsing and creation;
- `protocol` is never optional.

An alternative server intended for current clients should send every field in
the example, even if `harnesses` is an empty string.

## 8. Model readiness API

Model warm-up exists because several server processes or local workloads may
share memory and evict one another's configured models. Readiness is checked at
connection and immediately before each turn, not continuously.

### 8.1 Model states

| State | Meaning | Exposed to client? |
| --- | --- | --- |
| `unknown` | No check has completed since server start | Normally transient before handshake response |
| `checking` | Server is querying Ollama's running-model list | Internal transient state |
| `ready` | Configured model is resident and context allocation is known | Yes |
| `warming` | Disposable Ollama chat request is running | Yes |
| `error` | Residency check or warm-up failed | Yes |
| `unmanaged` | Client compatibility state for a legacy server | Client-only |

```text
unknown/error/ready
       │ forced ensure
       ▼
   checking ── resident ─────────────► ready
       │
       └── not resident ─► warming ── success ─► ready
                                  └── failure ─► error
```

The warm-up is a disposable, non-conversation Ollama `/api/chat` request built
from the stable agent prefix. Its output is parsed only to verify success. It
does not enter the transcript, model history, or session store.

### 8.2 `POST /v1/model/ensure`

Request body:

```json
{}
```

The body is not semantically used, but clients should send a valid empty flat
object.

The endpoint forces a fresh residency check unless an existing warm-up is
still incomplete. It starts warm-up when the configured model is absent.

Response:

```json
{"model_status":"warming","model_error":""}
```

or:

```json
{"model_status":"ready","model_error":""}
```

or:

```json
{"model_status":"error","model_error":"cannot connect to Ollama at ..."}
```

The endpoint itself returns 200 for these state results, including `error`.
A later `/v1/turn` returns 503 if preparation remains in the error state.

### 8.3 `GET /v1/model`

This endpoint collects the result of an already-started warm-up when it has
finished. It does not initiate a new residency check. Its response schema is
identical to `/v1/model/ensure`.

### 8.4 Client readiness algorithm

Before every prompt, a current client:

1. If handshake state is `unmanaged`, considers the legacy server ready.
2. Calls `POST /v1/model/ensure`.
3. If state is `warming`, shows `Warming Up` and repeatedly calls
   `GET /v1/model` until state changes.
4. Holds the prompt locally; it is not concurrently sent to the model.
5. If the user cancels before submission, returns cancellation locally while
   the server warm-up continues.
6. On `ready`, submits the turn.
7. On `error`, reports preparation failure and does not submit the prompt.

There is still a race between the readiness response and turn submission. The
turn endpoint repeats the check and can queue the prompt behind a new warm-up.

## 9. Starting a turn: `POST /v1/turn`

### 9.1 Request

```json
{"prompt":"Run the tests and explain any failures"}
```

`prompt` must be a JSON string and must be non-empty. A whitespace-only string
is technically non-empty and is accepted. There is no prompt-specific limit
beyond the total request-body limit.

### 9.2 Concurrency rule

Only one active or warm-up-queued turn is allowed for the entire named server.
The rule is not per client and not per session. If `active.pid` or
`pending_prompt` exists, the server returns:

```http
HTTP/1.1 409 Conflict

{"error":"a remote turn is already running"}
```

Session selection and creation are also blocked while a turn is active or
queued.

### 9.3 Accepted response

When the model is ready and a worker starts:

```http
HTTP/1.1 202 Accepted

{"turn_id":"1788012245_14723"}
```

When a second pre-turn residency check discovers eviction, the server stores
the exact prompt in private runtime state and returns:

```json
{"turn_id":"1788012245_14723","model_status":"warming"}
```

The current client does not use `turn_id` in later requests. It resets its
event cursor to zero and polls the one global current-turn event stream.
Alternative clients should retain `turn_id` for diagnostics but cannot pass it
back to protocol-1 event, approval, or cancellation endpoints.

### 9.4 Turn initialization

Before accepting a new turn, the server clears prior transient events,
approval responses, pending approval, pending prompt, and worker-done state.
It then either starts the worker or stores the pending prompt.

The worker:

1. closes inherited server/client TCP descriptors;
2. loads the selected server-side session;
3. enables persistent session writes;
4. restores a coding-profile `allow` policy remembered by the server process;
5. appends the user prompt to the server's exact-user ledger and visible
   transcript;
6. runs the normal agent loop, including project guidance, Skills, MCP, tools,
   compaction, workspace checks, and command approval;
7. saves the session;
8. persists any changed command policy;
9. publishes one `complete` event;
10. writes the worker-done marker and exits with the agent status.

If the worker cannot load the selected session, it emits an error message and
a completion with exit code 1.

### 9.5 Pending prompt progression

A queued prompt advances only when event polling calls the server's pending
turn progress function. Each `GET /v1/events` poll also polls the warm-up.

- When warm-up becomes `ready`, the server removes `pending_prompt` and starts
  exactly one turn worker with the stored text.
- When warm-up becomes `error`, the server removes the pending prompt, emits a
  visible error event, and emits completion with exit code 1.
- Cancellation removes the pending prompt and emits stopped/completion events.

An alternative implementation may progress warm-up independently, but it must
preserve exactly-once start behavior and the observable events.

## 10. Turn events: `GET /v1/events?after=N`

### 10.1 Polling contract

`N` must be a decimal non-negative integer. The response contains at most one
event: the first current-turn event whose sequence is greater than `N`.

If no later event exists, the server returns immediately with:

```json
{"event":"none"}
```

This is short polling, not long polling. The client waits briefly and requests
again. Event sequence numbers restart at 1 for every accepted turn because the
previous event directory is cleared. A client must reset its cursor to 0 after
`POST /v1/turn` succeeds.

Numbered responses include `seq`. The empty response does not.

### 10.2 Message event

```json
{
  "seq": 1,
  "event": "message",
  "role": "assistant",
  "content": "I found the failing test.",
  "thinking": "The failure points to the parser boundary."
}
```

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `seq` | number | Monotonically increasing current-turn event sequence |
| `event` | string | `message` |
| `role` | string | Normally `assistant`, `tool`, `system`, or `error` |
| `content` | string | Visible message text; may be empty when reasoning is present |
| `thinking` | string | Model reasoning text, possibly empty |

The server worker appends visible messages to persistent session storage before
or while publishing them to the transient stream. Reconnecting later restores
the transcript through the session API, not by replaying every old turn's
transient event files.

### 10.3 Status event

```json
{"seq":2,"event":"status","status":"Running tests"}
```

`status` is display text produced by the server-side agent. Clients should not
use arbitrary status strings as protocol state. Model readiness and completion
have their own fields and endpoints.

### 10.4 Approval-required event

```json
{
  "seq": 3,
  "event": "approval_required",
  "id": "1788012245_14723_20891",
  "command": "make test"
}
```

The client must show the exact `command` safely, collect a local decision, and
respond through `/v1/approval`. It should stop advancing the agent conceptually
until that response is accepted, although it may continue rendering UI.

### 10.5 Completion event

```json
{"seq":4,"event":"complete","exit_code":0}
```

Completion terminates the client's event loop. Exit codes from 0 through 255
are valid. The current client treats any other value as 1. Meaningful values
include:

- `0`: turn completed successfully;
- `1`: general agent or server failure;
- `130`: user cancellation or worker termination.

The current client refreshes its session list after completion when session
support is enabled.

### 10.6 Event publication requirement

Current zcoder writes each event as compact flat JSON to a private temporary
file, then atomically renames it to a zero-padded sequence filename. Pollers
therefore see either a complete event or no event. A replacement store must
provide the same atomic visibility and total order.

It must not publish partial JSON. It must not reorder approval-required and
completion events. It should preserve all current-turn events until the next
turn starts or until an explicit retention policy known to the client permits
deletion.

## 11. Command approval: `POST /v1/approval`

### 11.1 Request

```json
{"id":"1788012245_14723_20891","decision":"y"}
```

Allowed decisions are:

| Value | Meaning |
| --- | --- |
| `y` | Allow this exact command once |
| `a` | Request command allowance for the rest of the coding server process |
| `n` | Deny this exact command |

Success response:

```json
{"ok":true}
```

### 11.2 One-use matching

The server accepts the response only when:

- `id` is non-empty;
- it contains only digits and underscores;
- it exactly matches the current `pending_approval` value;
- the pending request has not expired or been cleared.

Otherwise it returns 409:

```json
{"error":"approval is missing, expired, or does not match"}
```

The response is published atomically to the waiting worker through a temporary
file and rename. The worker removes the pending marker and response after
consumption.

### 11.3 Timeout and policy

The worker waits up to `ZCODER_REMOTE_APPROVAL_TIMEOUT`, 300 seconds by default.
A missing or late response becomes `n` and fails closed.

An `a` decision updates the server process's persisted runtime policy to
`allow` only in the coding profile. The worker applies it to later commands and
later turns during that running server process.

The sysadmin profile still requires approval for every exact command. Although
the wire endpoint accepts the literal `a`, the sysadmin tool policy refuses to
turn it into session-wide authorization. `--yes` is also prohibited for a
sysadmin server.

If the server starts with `deny`, command execution is rejected without an
approval event. If a coding server starts with `allow`, commands run without an
approval event. None of these modes bypasses path confinement or the sysadmin
catastrophic-command guard.

### 11.4 Approval sequence

```text
Client                     Listener                  Turn worker
  │                           │                           │
  │ GET events after=N        │                           │
  │──────────────────────────►│                           │
  │ approval_required         │◄──── publish + wait ─────│
  │◄──────────────────────────│                           │
  │ show exact command        │                           │
  │ POST approval {id,y/a/n}  │                           │
  │──────────────────────────►│── atomic response file ─►│
  │ {ok:true}                 │                           │
  │◄──────────────────────────│                 resume or deny
```

## 12. Cancellation: `POST /v1/cancel`

Request body:

```json
{}
```

If a prompt is waiting for warm-up, cancellation removes it and publishes:

```json
{"event":"status","status":"Stopped"}
```

followed by:

```json
{"event":"complete","exit_code":130}
```

If a worker is active, the server sends `TERM`, waits for and reaps the child,
clears the active and approval markers, and synthesizes stopped/completion
events only if the worker did not already publish completion.

Success response:

```json
{"ok":true}
```

If neither an active worker nor a queued prompt exists, the server returns 409:

```json
{"error":"no remote turn is running"}
```

The current client deliberately ignores transport errors from its cancel
request and changes its local status to stopped. A more robust client should
report whether cancellation was acknowledged while avoiding a second unsafe
action.

Cancellation is cooperative at the server-worker boundary but forceful from
the agent's perspective. It cannot roll back workspace changes already made,
commands already run, or external side effects already committed.

## 13. Remote sessions

### 13.1 Ownership and scope

Sessions live below the named server's runtime, not in the client's local
session directory. They are filtered by the server's canonical workspace and
profile. A session for another workspace or profile is not visible through the
API even if it exists on disk.

Session IDs use:

```text
<positive-decimal-epoch>_<positive-decimal-random>
```

The current validator requires exactly two positive decimal components joined
by one underscore. Clients must treat the ID as opaque even though its current
format is visible.

### 13.2 List: `GET /v1/sessions?after=N`

`N` is a zero-based list cursor. The server refreshes the scoped list, orders
it by descending activity time, and returns item `N + 1`.

Example:

```json
{
  "event": "session",
  "seq": 1,
  "id": "1788012120_10392",
  "title": "Repair the deployment",
  "model": "qwen3-coder:latest",
  "current": 1,
  "empty": 0
}
```

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `event` | string | `session` |
| `seq` | number | One-based current list index and next cursor |
| `id` | string | Opaque safe session ID |
| `title` | string | Saved display title |
| `model` | string | Model saved with that session |
| `current` | number | `1` if selected by the named server, otherwise `0` |
| `empty` | number | `1` when both agent and visible event counts are zero, otherwise `0` |

At the tail:

```json
{"event":"none"}
```

The client starts with `after=0`, appends each `session` event, sets `after` to
the returned `seq`, and stops at `none`. It rejects a cursor that does not
strictly advance.

The cursor is an array index, not a stable snapshot token. If session ordering
changes during enumeration, items can theoretically move. A hardened API
should provide a snapshot ID or return the bounded list in one response, but a
protocol-1 adapter must preserve this one-item cursor behavior.

### 13.3 Transcript: `GET /v1/session?id=ID&after=N`

The literal query order is required: `id` first, then `after`. IDs need no URL
encoding under the current grammar.

The endpoint returns visible UI event `N + 1`:

```json
{
  "event": "message",
  "seq": 1,
  "role": "assistant",
  "content": "The tests pass.",
  "thinking": "I verified the focused and full suites.",
  "time": "21:27",
  "reasoning_open": 0
}
```

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `event` | string | `message` |
| `seq` | number | One-based transcript index and next cursor |
| `role` | string | Persisted UI role |
| `content` | string | Persisted visible content |
| `thinking` | string | Persisted reasoning |
| `time` | string | Display timestamp as stored by the server |
| `reasoning_open` | number | `1` if reasoning was expanded, otherwise `0` |

At the tail the response is `{"event":"none"}`. Invalid IDs, invalid cursors,
missing sessions, foreign workspace/profile scope, and missing required event
files all produce 404 with `remote session does not exist`.

This endpoint exposes the visible transcript, not every internal model message,
tool-call record, compaction checkpoint, or exact-user ledger entry.

### 13.4 Select: `POST /v1/session/select`

Request:

```json
{"id":"1788012120_10392"}
```

Success:

```json
{"ok":true}
```

The ID must exist and match the current workspace/profile scope. The server
updates `selected_session`. A missing or inaccessible ID produces 404.
Selection while a turn is active or waiting for warm-up produces 409.

The current client then refreshes the whole session list and loads the selected
transcript from cursor 0.

### 13.5 Create: `POST /v1/session/new`

Request:

```json
{}
```

The server resets agent and UI state, creates and persists a new empty session,
selects it, and returns:

```json
{"id":"1788012400_31942"}
```

Creation while a turn is active or queued produces 409. The current route does
not parse or use the request body, but compatible clients should send `{}`.

### 13.6 Client startup session rule

After a handshake advertising `sessions: true`, the current client:

1. enumerates all session summaries;
2. finds the server-selected session;
3. if the selected session is empty, loads and reuses it;
4. otherwise creates a fresh session and loads its empty transcript.

This prevents a new client launch from silently continuing a used job while
also avoiding a growing collection of duplicate blank sessions.

## 14. Complete client flow

```text
start
  │
  ├─ normalize host and load private token
  ├─ GET /v1/hello
  ├─ require protocol == 1
  ├─ adopt server workspace/model/profile/policy
  ├─ if sessions supported: enumerate, reuse blank or create new
  └─ display ready/warming/error state

submit prompt
  │
  ├─ POST /v1/model/ensure
  ├─ while warming: GET /v1/model
  ├─ on ready: POST /v1/turn
  ├─ reset event cursor to 0
  └─ loop GET /v1/events?after=cursor
       ├─ none: wait and repeat
       ├─ message: render and advance cursor
       ├─ status: update display and advance cursor
       ├─ approval_required: ask user, POST /v1/approval, advance cursor
       └─ complete: refresh sessions and return exit_code
```

For an interactive client, cancellation must remain responsive during model
warm-up and event polling. For a one-shot client, events should be rendered to
stdout/stderr with terminal control bytes made visible, and command approval
should fail closed when no safe interactive input channel exists.

## 15. Complete server flow

### 15.1 Startup

1. Validate port, non-empty server name, profile, and token file.
2. Derive the private named runtime.
3. Create private event, approval, and session storage.
4. Refuse a second live owner of the same runtime.
5. Clear stale per-turn state.
6. Store the configured command policy.
7. Initialize or resume server-owned session storage.
8. Restore the selected session if valid; otherwise select the current one.
9. Disable listener-side session writes so it cannot overwrite worker updates.
10. Bind the TCP listener and accept one connection at a time.

### 15.2 Per request

1. Read a bounded HTTP header and declared body.
2. Reject malformed framing before dispatch.
3. Authenticate before any endpoint behavior.
4. Reap a completed worker if its done marker is present.
5. Match the exact method and target.
6. Validate the flat JSON envelope and route-specific state.
7. Perform the operation.
8. Write one bounded JSON response with `Connection: close`.
9. Close the accepted descriptor on every path.

### 15.3 Shutdown

On normal shutdown, the owner process:

- terminates and reaps an active worker;
- removes active, pending-prompt, and server-owner markers;
- closes the listening descriptor;
- lets the application-wide cleanup stop MCP and temporary runtime services.

Persistent sessions, selected-session state, and named-server storage remain.

A hardened server should also handle unclean parent death, orphaned workers,
PID reuse, and crash-consistent approval/event recovery. Protocol 1 itself does
not define recovery after a process or machine crash.

## 16. Components required for an alternative implementation

A complete alternative server needs all of the following. Replacing only the
HTTP listener is insufficient.

### 16.1 Transport adapter

Responsibilities:

- accept TCP connections or terminate the replacement transport;
- enforce header/body/time bounds;
- calculate byte-correct lengths;
- close connections and descriptors reliably;
- expose a small request object containing method, literal target,
  authorization, and exact body;
- emit JSON responses and preserve non-2xx bodies;
- remain independently testable from the model and UI.

If the internal transport is streaming, the protocol-1 adapter must convert it
to the one-event-per-poll cursor API.

### 16.2 Authentication middleware

Compatibility mode needs exact bearer-token validation. Hardened mode should
add TLS, constant-time credential verification, token IDs or user identities,
expiry, rotation, rate limits, and audit records. Authentication must run
before model checks, session reads, or error messages that disclose server
state.

### 16.3 Named-server coordinator

This service owns:

- one server identity and display name;
- effective workspace/model/profile/policy;
- one selected session;
- one model-readiness state;
- no more than one active or queued turn;
- one pending command approval at a time;
- worker ownership and shutdown.

If a new implementation serves many logical servers in one process, each must
have a separate coordinator and must map a connection to the correct identity
without weakening authentication.

### 16.4 Agent-runtime adapter

The adapter must accept a prompt and selected session, run the normal iterative
agent loop, and emit message/status/approval/completion records. It must use the
server's project guidance, Skills, MCP registry, context policy, tool schemas,
and model configuration.

It must not let remote client metadata replace server authority. It must not
turn protocol requests directly into arbitrary filesystem or shell actions.

### 16.5 Workspace and tool-policy layer

Every built-in file operation must canonicalize paths, resolve symlinks, and
remain inside the configured workspace. `run_command` must continue through
the normal approval policy and safety guards. The remote API is not an
authorization bypass.

The implementation should separate:

- workspace-confined direct file tools;
- shell commands requiring approval or an explicit server policy;
- profile-specific guards;
- MCP tools and their own trust configuration;
- external processes and cleanup.

### 16.6 Model-readiness adapter

For Ollama compatibility this service needs:

- `GET /api/ps` or equivalent running-model inspection;
- exact configured-model matching;
- context allocation capture;
- a disposable warm-up request when absent;
- asynchronous completion collection;
- explicit `ready`, `warming`, and `error` states;
- a new forced check at handshake and before every turn;
- no continuous warm-up that makes multiple servers evict one another.

For another model provider, define what `ready` means. A stateless hosted API
may always be ready after credential/config validation and can implement ensure
as a cheap health/capability check.

### 16.7 Event store

Required properties:

- ordered sequence numbers starting at 1 per turn;
- atomic publication of complete flat JSON events;
- retrieval of the first sequence greater than a cursor;
- an unambiguous empty-tail response;
- retention through completion until a new turn begins;
- separation from durable transcript storage;
- safe concurrent writer/reader behavior.

An in-memory store is sufficient only if loss on process restart is acceptable.
The existing filesystem implementation makes event publication visible across
listener and worker processes.

### 16.8 Approval rendezvous

Required properties:

- unpredictable-enough unique ID tied to the active turn;
- exact one-use match;
- exact command text in the event;
- bounded wait with default denial;
- atomic response publication;
- cleanup after answer, timeout, cancellation, worker exit, and server exit;
- profile-aware handling of session-wide approval.

Do not accept an approval merely because it has a syntactically valid ID. It
must match the currently pending command.

### 16.9 Session store

Required properties:

- durable server-side model/tool history;
- durable visible UI transcript;
- workspace/profile scoping;
- safe opaque IDs;
- title, model, update time, and empty-state metadata;
- selection and creation only while idle;
- atomic or crash-consistent record updates;
- restoration of active Skills, context checkpoints, and other agent state
  needed for a faithful continuation.

The protocol exposes only summaries and visible transcript events; the internal
format may differ completely.

### 16.10 Process supervisor and cancellation

Required properties:

- start at most one worker;
- record worker ownership before reporting successful acceptance;
- close inherited network descriptors in children;
- detect normal worker completion;
- terminate and reap on cancellation and shutdown;
- prevent a stale or reused PID from targeting an unrelated process;
- synthesize exactly one completion if a terminated worker did not publish one;
- clean pending approval and prompt state on every exit path.

### 16.11 Presentation client

Required properties:

- handshake validation and optional-field compatibility;
- authoritative server metadata display;
- session enumeration and transcript loading;
- readiness checks and bounded polling;
- current-turn cursor tracking;
- terminal-safe rendering of untrusted remote text;
- exact command display and fail-closed approval input;
- responsive cancellation;
- correct exit-code propagation for one-shot use;
- no assumption that a transport acknowledgement means the agent completed.

## 17. Concurrency, multi-client, and idempotency semantics

Protocol 1 is intentionally single-flight and server-global.

- Multiple holders of the same token can connect.
- They see the same selected session, model state, active turn, approval, and
  event stream.
- Any authenticated client can poll or cancel the active turn.
- Any authenticated client can answer the pending approval if it knows the ID
  from the event stream.
- Event cursors are client-local, but event storage is global.
- Starting a new turn clears the previous turn's transient events.

Mutation requests have no idempotency key:

- If a `POST /v1/turn` response is lost after the worker starts, a blind retry
  normally receives 409. The client can poll events, but cannot prove from the
  API that the accepted turn corresponds to its prompt.
- Retrying `POST /v1/session/new` after an ambiguous failure can create another
  session.
- Retrying an already-consumed approval normally receives 409.
- Retrying cancellation after successful cancellation normally receives 409.

A semantic replacement should add authenticated client identities, turn IDs on
all turn-scoped requests, idempotency keys for mutations, and an event-stream
lease or subscription. A protocol-1 gateway can maintain those internally
while projecting the legacy global view.

## 18. Failure behavior

### 18.1 Client handling matrix

| Situation | Current expected client behavior |
| --- | --- |
| Cannot connect | Fail the request and display a remote-server transport error |
| 401 | Stop; token is missing or wrong |
| Handshake protocol not 1 | Stop as unsupported |
| Handshake field missing | Use documented legacy default where allowed |
| Model `warming` | Poll and hold prompt |
| Model `error` | Do not submit prompt |
| Turn 409 | Report that another remote turn is running |
| Event `none` | Wait briefly and poll again |
| Malformed event | Stop current client loop with an error |
| Unknown event type | Stop current client loop with an error |
| Approval POST failure | Report error, request cancellation, stop the turn loop |
| Completion | Return its validated exit code and refresh sessions |
| Session 404 | Report load/select failure without changing server state |

### 18.2 Server fail-closed rules

The server must:

- reject before dispatch when request framing is malformed;
- authenticate before returning server metadata;
- reject non-flat or malformed required JSON;
- reject a second active turn;
- reject session mutations while busy;
- deny approval on timeout, mismatch, or publication failure;
- reject a turn when model preparation is in error;
- publish an explicit failure completion when a queued prompt cannot start;
- keep shell command policy and workspace checks server-side.

### 18.3 Disconnects

HTTP requests are independent. Disconnecting a client does not cancel an active
turn. The server worker can continue, wait for approval until timeout, save its
session, and publish events. A later authenticated client can inspect the
selected session transcript.

Protocol 1 has no explicit client-presence lease. A hardened design should
decide whether client loss cancels work, lets it continue, or changes approval
timeouts, and should make that decision visible.

## 19. Security analysis

### 19.1 Current trust boundary

The bearer token prevents unauthenticated use but the native connection is not
encrypted. The token, prompts, reasoning, source excerpts, tool results,
commands, approvals, and transcripts are observable and modifiable by an
on-path attacker.

Use the native server only:

- on a trusted LAN with restrictive host firewall rules; or
- through an SSH port forward; or
- through a trusted VPN.

Do not expose port 7337 directly to the public internet.

### 19.2 Protocol-1 limitations

The current protocol provides no:

- TLS or server certificate validation;
- per-user identity or authorization scope;
- forward secrecy at the application layer;
- replay defense;
- request signing;
- CSRF/origin concept;
- rate limit or authentication backoff;
- audit identity beyond the shared token;
- response-size limit;
- stable multi-client ownership of turns;
- confidentiality separation between session readers and command approvers.

The listener handles connections serially in one process. A slow authenticated
or unauthenticated connection can consume listener time until its read timeout.
A production replacement should use bounded concurrency and global as well as
per-read deadlines.

### 19.3 Terminal safety

All server-originated strings are untrusted at the client, including server
name, workspace, model, messages, reasoning, tool output, errors, and exact
commands. They can contain escape, OSC, carriage-return, backspace, BEL, or
other control bytes.

An alternative client must render these visibly or through a UI primitive that
does not interpret terminal control sequences. Approval displays require the
strongest treatment because a forged visual command can mislead the operator.

### 19.4 Hardened replacement profile

A secure replacement should add:

1. TLS 1.2+ or another mutually authenticated encrypted transport.
2. Server identity verification and a documented trust bootstrap.
3. Per-client credentials with rotation, expiry, and revocation.
4. Separate permissions for viewing, prompting, approving, cancelling, and
   session administration.
5. Turn-scoped authorization and idempotency keys.
6. Constant-time secret comparison.
7. Bounded request and response sizes, connection count, and polling rate.
8. Structured security audit events without prompt or secret leakage.
9. Redaction rules for logs and metrics.
10. Robust process-instance ownership and crash recovery.

The current zcoder client rejects `https://`, so TLS cannot be placed directly
between that client and a protocol-1 server URL. Preserve compatibility by
terminating TLS, SSH, or VPN outside the client and exposing only a private
loopback `http://localhost:<port>` endpoint to it.

## 20. Compatibility profile versus hardened profile

| Concern | Exact protocol-1 profile | Recommended replacement profile |
| --- | --- | --- |
| Transport | Plain HTTP/1.1, connection close | HTTPS or authenticated encrypted stream |
| Authentication | One shared bearer token | Per-client short-lived credentials |
| API state | One global active turn | Turn-scoped resources |
| Events | Short poll, one flat event | Streaming or bounded batch with resumable cursor |
| Mutation retry | No idempotency | Required idempotency key |
| Session cursor | Mutable list index | Stable snapshot/opaque cursor |
| Approval | One global pending ID | Turn + command + client-bound approval capability |
| Listener | Serial accepts | Bounded concurrent connections |
| Persistence | Private filesystem rendezvous | Transactional store or crash-safe journal |
| Locking | PID liveness check | Exclusive instance lease with generation |
| Auditing | Debug logs only | Redacted identity-aware audit log |

An implementation can provide both profiles through a gateway. The gateway's
legacy side must retain flat envelopes and route shapes; its internal side can
use the hardened model.

## 21. API conformance tests

### 21.1 Transport tests

- Correct `Content-Length` for ASCII and multibyte UTF-8 bodies.
- One request and one response per connection.
- Empty GET body with length zero.
- Header names accepted case-insensitively.
- Exact bearer value required.
- Missing `Content-Length` is treated as zero in compatibility mode; hardened
  mode rejects it on body-bearing methods.
- Malformed, negative, and oversized `Content-Length` rejected.
- Header over 65,536 bytes rejected with 413 in compatibility mode.
- Body over configured maximum rejected with 413.
- Partial header and body reads assemble correctly.
- Read timeout closes the accepted descriptor.
- Chunked request content is never decoded; compatibility tests verify the
  endpoint sees only the declared `Content-Length` bytes, while hardened mode
  rejects chunked requests explicitly.
- Every response has JSON content type, no-store, length, and close headers.
- All descriptors close on success and every error path.

### 21.2 Authentication tests

- Missing token file is rejected at startup.
- Token shorter than 32 characters is rejected.
- A character outside the URL-safe grammar is rejected.
- Group-readable and world-readable files are rejected.
- Current-user 0600 and 0400 files are accepted.
- Trailing CR/LF is stripped but spaces are not silently accepted.
- Missing, malformed, and wrong bearer headers receive 401 for every route.
- No handshake metadata leaks before authentication.

### 21.3 Handshake and readiness tests

- Handshake requires protocol 1.
- Server metadata overrides client-local display settings.
- Missing readiness field activates legacy unmanaged behavior.
- Missing harness field remains unknown.
- Empty harness string is distinguishable from absent field.
- Missing/false sessions field disables session calls.
- Resident configured model returns ready without warm-up.
- Absent model starts exactly one warm-up.
- Incomplete warm-up remains warming.
- Successful warm-up becomes ready and refreshes context allocation.
- Failed inspection or warm-up becomes error with diagnostic text.
- A pre-turn eviction triggers a second warm-up and queues the exact prompt.

### 21.4 Turn and event tests

- Empty or non-string prompt receives 400.
- Valid prompt receives 202 and a turn ID.
- Concurrent turn receives 409.
- Events start at sequence 1 and remain strictly ordered.
- Poll returns the first sequence greater than the cursor.
- Empty tail is exactly a flat `none` event.
- Multiline content and reasoning round-trip exactly.
- Worker messages are both persisted and published.
- Completion carries the worker exit status.
- Invalid completion exit status is contained by the client.
- Starting a new turn clears prior transient events.
- Lost/disconnected client does not corrupt the worker or session.

### 21.5 Approval tests

- Approval event carries the exact command and a one-use ID.
- Correct `y` resumes once.
- Correct `n` denies once.
- Correct coding-profile `a` persists for later commands in the process.
- Sysadmin `a` does not create session-wide permission.
- Wrong, expired, already-used, or malformed IDs receive 409.
- Unsupported decision receives 400.
- Timeout denies and cleans pending state.
- Publication failure denies and cleans pending state.
- Cancellation while waiting removes pending approval and reaps worker.

### 21.6 Cancellation tests

- Active worker receives termination and is reaped.
- Queued prompt is removed before model execution.
- Exactly one completion with exit code 130 becomes visible.
- No-active-turn cancellation returns 409.
- Already-applied workspace changes are not represented as rolled back.
- A stale PID cannot terminate an unrelated process in the hardened profile.

### 21.7 Session tests

- Only matching workspace/profile sessions are listed.
- List is ordered by recent activity.
- Cursor advances one item at a time and terminates with `none`.
- Current and empty flags are correct.
- Transcript preserves content, reasoning, time, and visibility flag.
- Traversal and malformed IDs receive 404.
- Selecting a valid session updates durable selected state.
- Creating a session produces a safe ID and persists it immediately.
- Selection and creation receive 409 during active or queued work.
- Client launch reuses an empty selected session.
- Client launch creates a fresh session after a used selected session.

### 21.8 Security and fault-injection tests

- Control bytes are visible-safe in all client rendering surfaces.
- Approval text cannot inject terminal controls.
- Worker closes inherited listener and client descriptors.
- Server restart does not overwrite completed session state.
- Worker crash produces or allows synthesis of one failure completion.
- Disk-full and rename failures do not expose partial events or approvals.
- Server shutdown terminates owned workers and leaves durable sessions intact.
- Slow connections are bounded.
- Poll floods and authentication failures are rate-limited in hardened mode.

## 22. End-to-end acceptance scenarios

An implementation is functionally complete when all of these scenarios work.

### Scenario A: ready model, no command

1. Client authenticates and receives server authority.
2. Readiness check returns ready.
3. Client submits a prompt.
4. Server starts one worker and returns 202.
5. Client receives status/message events in order.
6. Server persists the transcript.
7. Client receives completion 0 and can reload the transcript from the session
   endpoint after reconnecting.

### Scenario B: model was evicted

1. Handshake or pre-turn ensure finds the model absent.
2. Server starts one disposable warm-up and returns warming.
3. Client holds or server queues the exact prompt.
4. Warm-up finishes and context allocation is refreshed.
5. Prompt starts once, without warm-up content entering the session.
6. Normal events and completion follow.

### Scenario C: command approval

1. Agent requests `run_command` under `ask` policy.
2. Worker publishes exact command and one-use ID, then blocks.
3. Client renders it safely and sends `y`, `a`, or `n`.
4. Server accepts only the matching live ID.
5. Worker resumes or denies according to profile policy.
6. Completion and session persistence remain ordered.

### Scenario D: cancellation

1. Client submits a long turn.
2. User cancels while warming, generating, running a tool, or waiting for
   approval.
3. Server removes the queued prompt or terminates and reaps the worker.
4. Pending approval state is cleared.
5. Client observes or locally reports stopped state and exit code 130.
6. A later turn can start without a stale busy marker.

### Scenario E: remote session navigation

1. Client enumerates summaries to `none`.
2. Client selects an older scoped session while idle.
3. Server persists selection.
4. Client loads every visible event to `none`.
5. A prompt continues that server-side model/tool history.
6. A new session request resets agent state and creates a durable empty job.

## 23. Recommended implementation sequence

1. Implement and test the flat JSON codecs and byte-counted HTTP framing.
2. Add authentication middleware and private named-server storage.
3. Implement `/v1/hello` with fixed ready state and a fake agent.
4. Implement the ordered event store and `/v1/events` cursor.
5. Add single-flight worker supervision and completion events.
6. Integrate the real agent runtime and workspace/tool policy.
7. Add approval rendezvous and timeout cleanup.
8. Add cancellation for active and queued states.
9. Add durable sessions, summaries, transcript loading, select, and create.
10. Add provider-specific readiness inspection and asynchronous warm-up.
11. Add backward-compatibility behavior for optional protocol-1 fields.
12. Run the conformance and fault-injection matrix.
13. Add the hardened transport, identities, idempotency, rate limits, and audit
    layer without weakening the protocol-1 adapter.

Keep tool dispatch independently testable from the network listener, curses,
and model provider. A transport request must never directly invoke a shell
command; it starts or controls the ordinary server-owned agent workflow.

## 24. Known protocol-1 constraints to resolve in a new design

Before designing a non-compatible API, make explicit decisions for each item:

- whether one server can run multiple turns concurrently in isolated sessions;
- how clients claim ownership of a turn;
- whether events stream, long-poll, or batch;
- how cursors resume after disconnect and server restart;
- how mutation idempotency works;
- how queued prompts survive or fail across restart;
- whether model readiness is meaningful for the selected provider;
- how credentials are issued, scoped, rotated, and revoked;
- whether viewers and approvers are separate roles;
- whether approval is bound to the exact normalized command, working directory,
  environment, and timeout rather than display text alone;
- what happens when the approving client disconnects;
- how session list snapshots remain stable;
- what transcript and reasoning data each role may read;
- how long events and sessions are retained;
- how response sizes and tool-output downloads are bounded;
- how server and worker crashes are recovered;
- how orphaned workers are identified without trusting reusable PIDs;
- how audit records avoid leaking prompts, source, tokens, and commands;
- how compatibility gateways expose the legacy global state safely.

## 25. Source map

The current behavior described here is implemented across:

| File | Relevant responsibility |
| --- | --- |
| `lib/remote.zsh` | Protocol client/server, API routing, events, approvals, readiness, cancellation |
| `lib/http.zsh` | Native TCP HTTP client, byte lengths, response parsing, async Ollama workers |
| `lib/json.zsh` | Flat-object parsing and JSON string encoding |
| `lib/agent.zsh` | Local/remote turn dispatch, emitted messages/statuses, normal agent loop |
| `lib/tools.zsh` | Workspace path checks, command safety, command approval policy |
| `lib/state.zsh` | Durable scoped sessions and visible transcript records |
| `zcoder.zsh` | CLI modes, startup authority, TUI integration, lifecycle cleanup |
| `tests/run.zsh` | Unit and integration contract coverage |

When exact wire compatibility matters, treat `lib/remote.zsh` in the target
release as the final executable authority. Protocol 1 has been extended with
optional capability fields and endpoints without changing its protocol number,
so a replacement should use capability detection rather than assuming every
protocol-1 peer implements every later feature.

[Documentation index](README.md) · [Remote-agent operator guide](remote.md) ·
[Architecture](architecture.md) · [Safety and permissions](safety.md)

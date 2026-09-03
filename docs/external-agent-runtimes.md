# External agent runtimes and subscription-backed models

Status: research decision record

Last verified: 2026-08-29

This document records the investigation into using the Codex Python SDK,
Claude Agent SDK, Google Antigravity SDK, and Antigravity CLI as model and
agent runtimes for zcoder. It exists so that later implementation work can
start from verified process and protocol boundaries instead of rediscovering
them.

The immediate motivation was access to state-of-the-art hosted models without
making Zsh implement HTTPS, TLS, Server-Sent Events, or secure WebSockets. A
libcurl helper and loadable Zsh module were explored first. That design remains
documented in [HTTPS and WSS through a libcurl bridge](libcurl-transport-bridge.md),
but it is shelved while provider-owned local runtimes offer a smaller and more
economical integration boundary.

## Decision summary

The important discovery is that none of the Python SDKs inspected is primarily
an in-process HTTPS client:

- the Codex SDK launches `codex app-server` and speaks structured JSON over
  stdio
- the Claude Agent SDK launches Claude Code and speaks a private NDJSON control
  protocol over stdio
- the Antigravity SDK launches a compiled Go `localharness`, bootstraps it with
  protobuf over stdio, then speaks protobuf-JSON over a loopback WebSocket
- Antigravity CLI independently exposes a documented, persistent NDJSON mode
  over stdio

Provider-owned processes already handle remote authentication, HTTPS, model
streaming, retries, and provider protocol changes. Zcoder can therefore keep a
local process boundary and avoid owning TLS or WSS.

The recommended order is:

1. use Antigravity CLI's documented `stream-json` mode for a persistent,
   subscription-backed, plan-only consultant
2. prototype a Codex app-server adapter for the richest supported integration
   and official ChatGPT authentication
3. extract a provider-neutral long-lived process manager only after the first
   adapter proves its requirements
4. keep the existing one-shot `/claude`, `/codex`, `/agy`, and `/opencode`
   delegates while persistent adapters mature
5. defer direct Antigravity `localharness` integration unless its local-model
   orchestration is valuable enough to justify protobuf and WebSocket work
6. do not build a Claude Agent SDK product path around personal claude.ai
   subscription credentials without explicit Anthropic approval

The libcurl bridge is not rejected. It becomes the fallback for providers that
do not ship a suitable local runtime or documented subprocess protocol.

## Zcoder's non-negotiable boundary

Zcoder is Zsh-first and supports Zsh 5.8 or newer. A new provider must not
weaken the properties that make the current agent safe and understandable:

- all model-exposed file operations remain confined to `ZCODER_WORKSPACE`,
  including after symlink resolution
- shell execution never bypasses the `run_command` approval policy
- model and provider output is untrusted data, never shell source, a pattern,
  a format string, or trusted terminal control data
- tool dispatch stays testable without curses or a live hosted model
- provider processes have explicit ownership, bounded input, cancellation,
  cleanup, and reaping
- secrets do not enter argv, transcripts, debug logs, session state, or error
  messages
- provider configuration, hooks, plugins, skills, and project instructions are
  part of the trust boundary
- no provider may silently convert a consultation into mutation authority

An external runtime can be used in three different roles. They must remain
distinct in code and in the interface:

| Role | Meaning | Authority |
| --- | --- | --- |
| Consultant | Returns analysis that zcoder treats as untrusted context | Read-only |
| Worker | Directly edits through the provider's own harness | Explicit one-shot authority, currently the bang commands |
| Primary runtime | Drives a multi-turn agent while zcoder owns tools and policy | Must route all effects through zcoder's boundary |

The consultant role is the smallest safe starting point. A worker is useful but
cannot satisfy the sysadmin profile's per-command approval invariant. A primary
runtime is the long-term goal, but only when tool requests can be intercepted
before execution.

## Research snapshot

The conclusions below were verified against these local checkouts and
executables:

| Component | Revision or version |
| --- | --- |
| Codex checkout | `f5636bb733c4653a6b91413fed1aaf8842374f2e` |
| Installed Codex CLI | `codex-cli 0.151.0` |
| Claude Agent SDK checkout | `af5ff1b9f2f279575f89b78f17572c6e35fbc2b6` |
| Claude Agent SDK package | `0.2.148` |
| Bundled/installed Claude Code | `2.1.251` |
| Antigravity SDK checkout | `ac516c7709e3baf225c09d8b9d112b07b70066ff` |
| Antigravity SDK package | `0.1.15` |
| Installed Antigravity CLI | `agy 1.1.22` |

These are alpha or fast-moving interfaces. Recheck the pinned source and
official documentation before implementation or release.

## Comparison

| Concern | Codex app-server | Claude Agent SDK | Antigravity localharness | `agy stream-json` |
| --- | --- | --- | --- | --- |
| Local runtime | Codex CLI | Claude Code | Bundled Go binary | Antigravity CLI |
| Initial transport | Stdio | Stdio | Binary protobuf over stdio | Stdio |
| Ongoing transport | JSON-RPC-style JSONL | Claude control NDJSON | `ws://localhost` protobuf-JSON | Documented NDJSON |
| Process/session model | One server, multiple threads | Normally one process per conversation | One harness per SDK session | One process, one continuous conversation |
| Protocol schemas | Generated app-server schemas | Handwritten Python types | Published `.proto` files | Documented event envelopes |
| Reverse requests | Approvals and server requests | Permissions, hooks, MCP | Tools, hooks, policy decisions | No control requests in stream mode |
| Cancellation | `turn/interrupt` | `interrupt` control request | `halt_request` | Process/signal boundary |
| Model switching | Request methods and turn options | `set_model` control request | Harness configuration | Fixed at process launch |
| Subscription path | Official ChatGPT login | Not a general third-party SDK path | SDK uses API or local backends | Official cached Antigravity credentials |
| Local models | Not the purpose | No | LiteRT and OpenAI-compatible endpoints | No SDK-style endpoint override |
| Zsh difficulty | Moderate | Moderate, fragile | High | Low |
| Best initial use | Full integration research | Existing one-shot delegate | Local-harness research | Persistent consultant |

## Shared architectural lesson

The provider SDKs confirm a useful boundary:

```text
zcoder
  |
  | local structured protocol
  v
provider-owned runtime
  |
  | provider authentication and HTTPS/WSS
  v
hosted model service
```

This keeps Zsh on the side of the boundary where it is strong:

- process ownership
- arrays and exact argv construction
- line-oriented framing
- JSON parsing and normalization
- file-descriptor polling
- explicit state machines
- Unix-domain sockets
- policy and user interaction

It leaves TLS, HTTP/2, cloud authentication, provider retries, and rapidly
changing remote event formats with the provider runtime. This is a better use
of Zsh than reimplementing those layers or loading a large native networking
stack into the shell process.

The exception is Antigravity `localharness`: its local boundary includes binary
protobuf and WebSocket framing. Both are possible in Zsh, but implementing both
would cross from productive systems work into fighting the language.

## Codex Python SDK

### What the SDK contains

The Python package is a typed client for `codex app-server`, not a Python port
of the Codex agent loop. It resolves a matching Codex executable and launches:

```text
codex app-server --listen stdio://
```

The client writes one JSON request per line to stdin and runs one reader for the
ordered stdout stream. That reader routes responses by request ID and
notifications by login, thread, turn, or goal identity. Stderr is drained
separately into a bounded diagnostic buffer.

Relevant local sources:

- `sdk/python/src/openai_codex/client.py`
- `sdk/python/src/openai_codex/_message_router.py`
- `sdk/python/src/openai_codex/generated/v2_all.py`
- `sdk/python/src/openai_codex/generated/notification_registry.py`
- `sdk/python/scripts/update_sdk_artifacts.py`

The generated types come from an app-server schema bundle. That is a major
advantage over reconstructing a private protocol from examples: methods,
notifications, enums, and payload changes can be diffed and fixtures can be
generated from the same source.

### Protocol lifecycle

A client starts with an initialization request and notification:

```json
{"id":"1","method":"initialize","params":{"clientInfo":{"name":"zcoder","title":"zcoder.zsh","version":"0.9.0"},"capabilities":{"experimentalApi":true}}}
{"method":"initialized"}
```

The important operations include:

- `account/read`, account login, and logout
- `model/list`
- `thread/start`, `thread/resume`, `thread/read`, and `thread/list`
- `thread/fork`, archive, unarchive, rename, and compact
- `turn/start`, `turn/steer`, and `turn/interrupt`
- streamed `turn/started`, item, delta, and `turn/completed` notifications
- server-initiated approval requests

One app-server process can own multiple Codex threads and route multiple active
turn streams. Zcoder does not need one operating-system process for every
conversation.

A critical race is documented in the Python router: turn notifications can
arrive immediately after `turn/start`, before the caller has registered a
consumer. The router temporarily retains early events. A Zsh implementation
must provide the same behavior rather than assuming response-before-event
ordering.

### Authentication and economics

The SDK explicitly reuses existing Codex authentication and exposes ChatGPT
browser login, device-code login, and API-key login. The local installation was
logged in through ChatGPT during the investigation. This makes Codex the
strongest candidate for a supported subscription-backed integration.

See the official [Codex SDK documentation](https://developers.openai.com/codex/sdk/),
[app-server protocol reference](https://developers.openai.com/codex/app-server/),
and the local SDK README under the inspected checkout. Authentication policy
and subscription eligibility are time-sensitive and must be rechecked before a
release.

### Zsh mapping

The transport maps naturally to a named `zpty` worker or an owned process with
dedicated descriptors:

1. start one app-server with an argv array
2. send bounded JSONL requests with unique IDs
3. maintain an association from request ID to pending operation
4. maintain per-turn event queues keyed by turn ID
5. retain early turn events until `turn/start` returns the ID
6. route server-initiated approval requests to the foreground policy/UI layer
7. keep stderr out of the protocol parser and retain only a bounded tail
8. interrupt active turns before terminating the process
9. close descriptors, terminate, escalate if needed, and reap the exact PID

The native JSON implementation can decode the wire objects. The generated
Python models should not be copied wholesale. Zcoder needs a deliberately small
method and event subset, plus fixtures exported from the schema version tested.

### Approval boundary

App-server approval requests are promising, but receiving an approval request
is not by itself enough. A full primary-runtime integration must ensure that:

- the exact proposed command or mutation is visible to zcoder before execution
- the active coding or sysadmin policy is applied
- denials fail closed
- approval IDs are one-use and tied to the current turn
- provider sandboxing cannot expand `ZCODER_WORKSPACE`
- a stale response cannot approve a later request

The safest design is to disable provider-owned mutating tools and expose
zcoder-owned tools through an explicit bridge, such as a narrowly scoped local
MCP server. If Codex executes a command itself, mapping its approval request to
zcoder's modal preserves user review but does not automatically apply every
guard in `run_command`. This must be resolved before calling Codex a primary
runtime rather than a consultant or external worker.

### Codex conclusion

Technically feasible, supported, schema-backed, and economically aligned with
the goal. This is the best candidate for deep integration.

## Claude Agent SDK

### What the SDK contains

The Python SDK bundles or locates Claude Code and launches it with a command
equivalent to:

```text
claude --output-format stream-json --verbose \
  --input-format stream-json [configuration arguments...]
```

The environment normally removes inherited `CLAUDECODE` and sets:

```text
CLAUDE_CODE_ENTRYPOINT=sdk-py
CLAUDE_AGENT_SDK_VERSION=<sdk-version>
```

Relevant local sources:

- `src/claude_agent_sdk/_internal/transport/__init__.py`
- `src/claude_agent_sdk/_internal/transport/subprocess_cli.py`
- `src/claude_agent_sdk/_internal/query.py`
- `src/claude_agent_sdk/client.py`
- `src/claude_agent_sdk/types.py`

The default transport is one Claude Code subprocess with stdin, stdout, and
optional stderr pipes. The protocol is one JSON object per line. The SDK uses
a line framer because asynchronous reads are chunks rather than message
boundaries and applies a one-megabyte default maximum message buffer.

### Control protocol

SDK-to-CLI calls use a request envelope:

```json
{
  "type": "control_request",
  "request_id": "req_1_abcd1234",
  "request": {
    "subtype": "initialize",
    "hooks": null
  }
}
```

The response is:

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_1_abcd1234",
    "response": {}
  }
}
```

The CLI can also send `control_request` messages back to the SDK. The client
handles at least:

- `can_use_tool`
- `hook_callback`
- `mcp_message`

Outgoing controls include:

- `initialize`
- `interrupt`
- `set_permission_mode`
- `set_model`
- `rewind_files`
- MCP status, reconnect, and toggle operations
- context usage
- background task stop

Ordinary output includes `user`, `assistant`, `system`, `result`,
`stream_event`, and `transcript_mirror` records. A string prompt is sent as:

```json
{
  "type": "user",
  "session_id": "default",
  "message": {"role":"user","content":"Review this repository."},
  "parent_tool_use_id": null
}
```

The `result` record is the turn boundary and carries the session ID, usage,
cost, errors, permission denials, and terminal reason.

### Complexity hidden by Python

The protocol itself is manageable, but the production client also handles:

- serialized writes
- response waiters and reverse requests
- cancellation of in-flight control handlers
- hooks and SDK-hosted MCP bridges
- tasks that outlive a foreground result
- determining when stdin may be closed safely
- transcript mirroring and custom session stores
- resume materialization and temporary configuration directories
- graceful wait, terminate, and kill escalation
- malformed JSON, non-JSON stdout, truncated frames, and bounded stderr

One Claude process normally represents one conversation. This differs from one
Codex app-server managing several threads.

The SDK's transport base class is explicitly described as an internal API that
may change or be removed in a future release. There is no equivalent generated
schema bundle; the wire types are handwritten Python `TypedDict` definitions.

### Empirical Zsh probe

A bounded Zsh probe launched the installed Claude Code binary, sent only the
`initialize` control request, received a successful control response, then
closed and reaped the process:

```text
handshake=success
elapsed=1.5 seconds
```

No user prompt or model turn was sent. The result proves that Zsh can speak the
framing and control protocol.

The probe also received `SessionStart` hook events from the user's existing
Claude configuration. Merely starting the runtime can therefore load provider
settings, plugins, and hooks. A real integration must deliberately isolate or
filter Claude configuration rather than inheriting it accidentally.

### Authentication and policy

This route does not solve the API-pricing concern. Anthropic's current Agent
SDK quickstart requires an API key or supported cloud-provider credentials.
Anthropic also states that third-party developers may not offer claude.ai login
or subscription rate limits without prior approval.

References:

- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Claude Agent SDK quickstart](https://code.claude.com/docs/en/agent-sdk/quickstart)
- [Hosting the Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/hosting)

An initialization handshake succeeding with local credentials does not prove
that a subscription-backed third-party model turn is permitted. No model call
was made to test that boundary.

### Claude conclusion

Technically feasible but based on a private, unstable protocol and an
authentication model that conflicts with the original economic goal. Keep the
existing `/claude` delegate. Reconsider a persistent SDK adapter only if
Anthropic provides a documented cross-language protocol and an approved
subscription path, or if the user explicitly accepts API/provider billing.

## Google Antigravity SDK

### What the SDK contains

The Python package is a control and convenience layer around a compiled Go
runtime named `localharness`. The runtime binary is included in
platform-specific PyPI wheels; cloning the source repository alone is
insufficient. The inspected checkout did not contain the binary or generated
`localharness_pb2.py`, and `google-antigravity` was not installed in the active
Python environment, so no live harness handshake was attempted.

Relevant local sources:

- `google/antigravity/agent.py`
- `google/antigravity/conversation/conversation.py`
- `google/antigravity/connections/local/local_connection.py`
- `google/antigravity/connections/local/event_processor.py`
- `google/antigravity/proto/localharness.proto`
- `google/antigravity/proto/content.proto`

The package exposes three layers:

| Layer | Responsibility |
| --- | --- |
| `Agent` | High-level lifecycle, tool wiring, hooks, triggers, and policy checks |
| `Conversation` | Stateful turns, history, streaming, compaction, and usage |
| `Connection` | Process, transport, backend, and protocol abstraction |

### Bootstrap and WebSocket protocol

Startup uses two protocols:

```text
Python SDK
  |
  | 4-byte little-endian length + binary protobuf InputConfig
  v
localharness stdin

localharness stdout
  |
  | 4-byte little-endian length + binary protobuf OutputConfig
  | OutputConfig contains a random port and API key
  v
Python SDK
  |
  | ws://localhost:<port>/ with x-goog-api-key
  v
localharness WebSocket
  |
  | protobuf messages serialized as JSON text
  v
conversation
```

The loopback connection is plain `ws://`, not `wss://`; it is local and
authenticated with a process-generated key. The harness owns remote provider
communication separately.

After connecting, the SDK sends an `InitializeConversationEvent` containing a
large `HarnessConfig`. The harness responds with an `OutputEvent` carrying
conversation identity, restored history, and cumulative usage. Ongoing input
and output are protobuf JSON objects.

Published protocol messages include:

- user text and multimodal input
- streaming text and thinking deltas
- trajectory and subagent state
- built-in and custom tool steps
- `ToolCall` and `ToolResponse`
- `PolicyDecisionRequest` and `PolicyDecisionResponse`
- lifecycle hook requests and responses
- user questions and answers
- halt and session-end requests
- per-agent and cumulative usage
- budgets for model calls, tool calls, and tokens

The checked-in `.proto` definitions are a strong compatibility asset, although
there is no explicit protocol-version negotiation in the bootstrap fields that
were inspected. The SDK and harness binary should be pinned as one release.

### Model backends

Antigravity separates the agent harness from model inference:

| Configuration | Backend | Authentication |
| --- | --- | --- |
| `LocalAgentConfig` | Gemini API or Vertex/Enterprise | API key or Google Cloud credentials |
| `LiteRTAgentConfig` | LiteRT-LM on the local machine | None |
| `LocalOpenAIAgentConfig` | Ollama, LM Studio, or another local OpenAI-compatible endpoint | None by default |

This makes `localharness` interesting for a different reason than hosted model
access: it could supply a sophisticated agent loop, subagents, policies,
compaction, MCP, hooks, and budgets while continuing to use Ollama.

That option has a strategic cost. Zcoder would delegate its agent loop to a
compiled runtime whose implementation is not present in this source checkout.
It would become an Antigravity frontend rather than a Zsh-first agent loop.
That may be worthwhile as an optional backend, but it should not silently
replace the native architecture.

### Safety findings

The source and README disagree about defaults. The README says `Agent` is
read-only by default. The current `LocalAgentConfig` source constructs a
`CapabilitiesConfig` with all built-in tools visible and uses
`confirm_run_command()` as its default policy. Without a handler, that policy
denies `run_command` but allows the wildcard remainder, including file creation
and editing.

Never rely on those defaults. A zcoder adapter must provide an explicit
allowlist and explicit policy configuration.

For a primary-runtime experiment:

- disable every harness-side file mutation and command tool
- disable subagents until their workspace and policy inheritance is proven
- expose only custom tools whose schemas map to zcoder dispatch
- answer `ToolCall` only after normal argument validation and approval
- return `ToolResponse` with bounded, redacted output
- use `PolicyDecisionRequest` only as an additional guard, not a replacement
  for zcoder policy
- use one exact workspace and independently validate symlink containment
- isolate app data and session storage from the project workspace

### Zsh feasibility

The JSON event phase is suitable for Zsh. The bootstrap and WebSocket layers
are not.

A native implementation would need:

- protobuf varint and length-delimited field encoding for `InputConfig`
- protobuf parsing for `OutputConfig`
- TCP connection and HTTP WebSocket upgrade
- validation of `Sec-WebSocket-Accept`
- client masking, frame lengths, fragmentation, ping/pong, and close handling
- partial binary reads and writes
- random masking keys and bounded reassembly
- protobuf-JSON construction and parsing after connection

`zsh/net/tcp` and `zsh/system` make this possible, but it duplicates protocol
machinery with little product benefit. Using `websocat`, Python, or a native
helper would undermine the goal of a direct Zsh port, while a libcurl helper
returns to the design currently being shelved.

### Antigravity SDK conclusion

Do not port `localharness` transport first. Preserve it as a research option
for an advanced local-model backend. The public protocol is unusually complete,
but the integration crosses the boundary where Zsh would begin fighting the
transport rather than benefiting from it.

## Antigravity CLI (`agy`)

### Documented persistent mode

The installed CLI exposes the simplest useful interface discovered in this
research:

```zsh
agy \
  --input-format stream-json \
  --output-format stream-json \
  --mode plan \
  --sandbox \
  --disable-slash-commands
```

It reads one NDJSON user event per line:

```json
{"event":"user","message":{"content":"Review the proposed design."}}
```

It emits:

1. one `init` event when the process starts
2. zero or more `step_update` events for each turn
3. exactly one `result` event for each submitted user event

Example shapes:

```json
{"event":"init","conversation_id":"...","init":{"cwd":"/workspace","tools":[],"permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"...","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"..."}}
{"event":"result","result":{"conversation_id":"...","status":"SUCCESS","response":"...","num_turns":1,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}
```

The process maintains one continuous conversation across input lines. The
`conversation_id` remains stable, `init` is emitted only once, and cumulative
turn, duration, and usage counters appear in later results. The application
must read stdout continuously and wait for the current `result` before sending
the next prompt. Closing stdin allows the active turn to finish, emits its final
result, and exits cleanly.

Official reference:

- [Antigravity CLI headless mode](https://www.antigravity.google/docs/cli/headless/)

### Stream limitations

The input protocol accepts user messages, not general control requests:

- `control_request` and `control_response` terminate the session with an error
- CLI-handled slash commands such as `/model` and `/usage` are unavailable
  inside the stream
- only text content blocks are accepted
- model, effort, agent, permission mode, and sandbox are selected at process
  launch
- changing those settings requires a new process
- malformed JSON terminates the session

There is no documented in-stream interrupt or approval response. Cancellation
therefore uses the owned process/signal boundary. A graceful close waits for the
active turn; an immediate user cancellation must signal or terminate the exact
owned process and tolerate already-completed provider effects.

### Authentication and economics

Headless mode uses credentials cached by an earlier interactive `agy` login.
It is explicitly part of the Antigravity CLI product surface and uses the
account's baseline quota. Google AI Pro and Ultra plans receive higher quotas;
accounts without those plans still receive a smaller baseline allocation.

Purchased AI-credit overages are separate. Users who want a hard subscription
boundary should configure overages to `Never` or disable the corresponding
credit setting. When quota is exhausted, the provider should fail visibly
rather than silently consuming paid credits.

References:

- [Antigravity CLI installation and authentication](https://www.antigravity.google/docs/cli/install/)
- [Antigravity plans](https://www.antigravity.google/docs/plans/)
- [Antigravity AI credits](https://www.antigravity.google/docs/cli/credits/)

The CLI can expose Gemini and selected third-party models according to the
user's current plan and region. Model availability is time-sensitive and must
be discovered with `agy models`, not hard-coded from this document.

### Approval boundary

The CLI's headless stream reports tool steps after the harness handles them; it
does not offer a bidirectional approval message. Headless permission policy can
soft-deny operations that require interaction, but current documentation says
workspace file reads and writes may be auto-allowed.

Consequences:

- an `agy` persistent adapter must start as a plan-only consultant
- always pass `--mode plan` and `--sandbox`
- never pass `--dangerously-skip-permissions`
- provider tool events are observations, not requests that zcoder may approve
- do not claim that `agy` tool execution passes through `run_command`
- do not enable this path as a worker in the sysadmin profile

The existing one-shot `/agy!` worker remains a separate explicitly authorized
feature with the trust model already described in [Safety and permissions](safety.md).

### `agy` conclusion

This is the best immediate route to subscription-backed SOTA consultation. It
uses a documented protocol, ordinary line framing, cached product credentials,
and one long-lived process. It does not yet provide the reverse tool-control
channel required for a primary zcoder runtime.

## Proposed provider-neutral process layer

Do not force the four transports into one wire protocol. Share lifecycle and
framing machinery while keeping provider semantics in adapters.

### Responsibilities

The common process layer should own:

- exact argv arrays and a deliberately filtered environment
- working directory
- named process identity and generation
- stdin, stdout, and stderr descriptors
- bounded line buffers
- write serialization
- readiness, busy, idle, stopping, failed, and closed states
- timeout and cancellation
- stderr tail retention with secret redaction
- exact PID ownership and reaping
- restart after protocol or process failure

Provider adapters should own:

- initialization messages
- request ID generation and routing
- event classification
- turn/session identity
- model and sandbox options
- authentication-specific diagnostics
- normalized content, reasoning, tool, usage, and terminal events
- protocol-version compatibility

The agent loop and UI should consume normalized events only.

### Suggested normalized events

```text
provider_started
session_started
turn_started
content_delta
reasoning_delta
tool_proposed
tool_started
tool_completed
approval_requested
usage_updated
turn_completed
provider_warning
provider_failed
provider_stopped
```

Every event should carry a provider, process generation, session ID when known,
turn ID when known, and bounded payload. A terminal event is accepted only for
the active generation and active turn.

### Zsh process design

Avoid the global unnamed coprocess channel for reusable library code. Starting
a second coprocess can replace the first. Named `zpty` workers or explicit
descriptor ownership are better when Codex and Antigravity may coexist.

Each reusable function should begin with `emulate -L zsh`, construct commands
as arrays, and preserve caller options, traps, aliases, descriptors, and
terminal state. Reads must use `IFS= read -r` and retain incomplete lines until
the delimiter arrives. A provider line must be bounded before JSON decoding.

The curses loop can watch provider descriptors with `zle -F` or its existing
poll boundary. A callback must:

1. verify the descriptor and process generation
2. consume all currently complete bounded frames
3. route them without directly mutating curses from a background child
4. unregister and close on EOF or error
5. reject stale results
6. repaint only when visible state changed

Provider stdout is protocol-only. Provider stderr is diagnostics-only. A child
must never write directly to the interactive terminal.

### State machine

```text
stopped
  -> starting
  -> ready
  -> turn_running
  -> ready
  -> stopping
  -> stopped

starting | ready | turn_running
  -> failed
  -> stopping
  -> stopped
```

Codex may allow several active turns, so its adapter can extend `ready` into a
bounded set of per-turn states. The first implementation should remain
single-flight until routing, cancellation, and UI semantics are proven.

### Backpressure and bounds

Initial conservative limits should include:

| Data | Suggested initial bound |
| --- | ---: |
| One protocol line | 1 MiB |
| Incomplete stdout buffer | 2 MiB |
| Retained stderr lines | 200 |
| Retained stderr bytes | 256 KiB |
| Pending requests | 16 |
| Early events per turn | 128 |
| Provider processes | 2 |

These are design starting points, not final configuration. Oversized input is a
protocol failure. Do not truncate JSON and continue parsing it as if complete.
Text displayed to the user can be truncated after successful decoding while
the protocol envelope remains exact.

## Implementation phases

### Phase 0: preserve current delegates

Keep one-shot consultants and explicitly authorized workers working while the
new path develops. Their current behavior is useful and provides fallback when
a persistent runtime fails.

### Phase 1: persistent `agy` consultant

- start `agy` in plan and sandbox mode
- send one user event at a time
- normalize `init`, `step_update`, and `result`
- stream text into a consultant transcript role
- surface cumulative usage and quota failures
- cancel by terminating the exact owned process
- restart cleanly after malformed input or model/config changes
- never execute or approve tools through this adapter

This phase validates long-lived provider process management with the simplest
documented protocol.

### Phase 2: Codex app-server spike

- initialize app-server
- read account and model metadata
- start one read-only thread
- start, stream, complete, and interrupt one turn
- prove early-notification buffering
- record unknown notifications without failing known turns
- map one approval request into a fail-closed test handler
- generate/update protocol fixtures from the pinned schema

Do not enable workspace writes until the approval and tool ownership design is
settled.

### Phase 3: common provider manager

Extract shared child lifecycle, descriptor polling, bounded framing, stderr,
cancellation, and restart logic only after phases 1 and 2 reveal their real
commonalities. Keep wire parsing in separate adapters.

### Phase 4: primary-runtime tool bridge

Investigate a local zcoder-owned MCP server or equivalent reverse tool channel.
The provider may plan and request tools, but zcoder validates and executes every
effect. Required proof includes workspace symlink escapes, command approval,
stale approval IDs, cancellation races, and sysadmin behavior.

### Phase 5: optional Antigravity localharness spike

Only if its local-model harness is strategically valuable:

- install a pinned wheel in an isolated development environment
- extract and hash the matching `localharness`
- generate bindings or minimal fixtures from the checked-in proto
- validate bootstrap without a model turn
- use a temporary private app-data and save directory
- disable all harness-side mutating tools
- test one custom tool round trip against a local OpenAI-compatible model

Do not begin by implementing WebSocket framing in the main application.

## Security test matrix

Every persistent provider adapter needs tests for:

- missing executable and unsupported version
- startup timeout and authentication required
- malformed JSON before initialization
- non-JSON stdout
- partial line followed by EOF
- oversized line and unbounded no-newline output
- stderr flood
- provider exit before response
- response arriving before request registration
- duplicate and unknown request IDs
- stale events from a replaced process generation
- cancellation before start, during streaming, and after completion
- graceful close timeout, terminate escalation, and kill escalation
- child and descendant cleanup
- workspace path traversal and symlink escape
- terminal control bytes in model, tool, and error text
- secret-like values in stderr and protocol diagnostics
- inherited hooks, plugins, settings, and environment variables
- quota exhaustion without paid-overage fallback
- refusal to run a mutating provider in the sysadmin profile

Integration tests should use fake provider processes with deterministic JSONL
fixtures. Live model tests should be opt-in, never part of `make test`, and
should state whether they may consume quota or paid credits.

## Open questions

- Should a persistent provider remain a named consultant, or may it become the
  primary reasoning runtime for an entire zcoder session?
- Should provider threads map one-to-one to zcoder jobs, workspaces, or both?
- Can Codex built-in tools be disabled completely while retaining its agent
  loop and exposing only zcoder-controlled tools?
- Is a small local MCP server the cleanest provider-neutral reverse tool
  boundary?
- How should provider context usage map to zcoder's `/context` display when the
  provider owns compaction?
- Should session persistence retain provider thread IDs, or deliberately start
  ephemeral provider sessions?
- How should a provider model change invalidate or restart a persistent process?
- Can `agy` add documented control messages or interactive approvals to its
  stream protocol in a future release?
- Does Antigravity `localharness` have an independent compatibility or protocol
  version contract beyond the wheel version?
- What user-facing setting makes paid overages impossible across every hosted
  provider?

## Final recommendation

Push Zsh hard where it remains expressive: long-lived child processes, framed
stdio, event routing, state machines, approval UI, and workspace policy. Do not
push it into TLS, WebSocket framing, or broad protobuf runtime implementation
when provider-owned processes already expose safer local protocols.

The immediate high-value experiment is a persistent plan-only `agy` consultant.
The most capable long-term integration is Codex app-server with a strict
zcoder-owned tool boundary. Claude remains a useful installed delegate but not
an approved subscription-backed SDK foundation. Antigravity `localharness`
remains a fascinating optional backend for local models, not the first hosted
model transport.

[Documentation index](README.md) · [Architecture](architecture.md) ·
[Safety and permissions](safety.md) ·
[HTTPS and WSS libcurl bridge](libcurl-transport-bridge.md)

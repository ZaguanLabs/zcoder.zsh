# HTTPS and WSS through a libcurl bridge

Status: exploratory design

This document defines a path from zcoder's native local HTTP transport to
HTTPS and secure WebSockets without making Zsh responsible for TLS or every
wire-level protocol edge case. The goal is access to hosted model APIs while
preserving zcoder's Zsh-first architecture, inspectability, cancellation model,
and safety boundaries.

Two libcurl integrations are worth exploring:

1. a small standalone C helper with a private framed connection to Zsh
2. a dynamically loadable Zsh module that exposes libcurl-backed builtins

Both must implement one Zsh-owned transport contract. The helper is the
recommended production starting point because it isolates native crashes and
does not depend on Zsh's internal ABI. The module is a deliberate research
track, not a prerequisite for hosted models.

## Decision summary

The initial direction is:

- keep `lib/http.zsh` as the native `ztcp` HTTP/1.1 transport for local and
  trusted-LAN Ollama endpoints
- define a provider-neutral asynchronous transport API in Zsh
- implement HTTPS, streaming HTTP, and WSS first in an isolated libcurl helper
- keep provider request and response semantics in Zsh
- carry credentials over a private channel, never process arguments
- normalize helper events before they reach the agent loop or persistent state
- prototype a loadable `zcoder/curl` module against the same contract
- ship the module only if it provides a demonstrated benefit that justifies its
  ABI, packaging, and in-process failure costs

This is not a decision to replace the existing native HTTP client. Local
Ollama remains the simplest and most inspectable route. Hosted transports add
capability rather than becoming a mandatory dependency.

## The boundary

Zsh should continue to own:

- provider selection and configuration
- request construction and response normalization
- model, conversation, reasoning, and tool-call state
- retry and cancellation policy
- context accounting and persistence
- command approval and workspace policy
- UI events and terminal rendering
- child ownership, health checks, and cleanup

libcurl should own:

- TLS negotiation and certificate validation
- DNS and proxy behavior
- HTTP version negotiation
- redirects when explicitly permitted
- streaming socket reads and writes
- WebSocket upgrade and framing
- client masking, fragmentation, ping/pong, and close frames
- partial native I/O and protocol error classification

The division is intentional: Zsh owns meaning, policy, and lifecycle; libcurl
owns cryptography and transport correctness.

## Goals

- reach hosted model APIs over verified HTTPS
- support incremental server-sent events or equivalent streaming responses
- support long-lived full-duplex WSS sessions where a provider benefits from
  them
- keep the TUI responsive and preserve Escape cancellation
- prevent secrets from entering argv, logs, transcripts, or session files
- retain a small, explicit interface between native code and Zsh
- keep the agent loop independent of provider and transport details
- allow helper and module backends to be tested against the same fixtures
- preserve Zsh 5.8 or newer for the main application

## Non-goals

- implementing TLS primitives in Zsh
- replacing libcurl's certificate, proxy, HTTP/2, HTTP/3, or WebSocket logic
- exposing arbitrary libcurl options directly to the model
- making remote hosted models mandatory for local zcoder operation
- loading native code from a project workspace
- automatically downloading or executing an unverified helper or module
- embedding provider-specific JSON parsing in the C layer
- permitting silent retries that may duplicate a paid or mutating request

## Why not only invoke `curl`?

The curl command is the smallest path to ordinary HTTPS request/response and
may be sufficient for the first HTTPS spike. It already supplies mature TLS,
certificate stores, proxies, and HTTP version negotiation.

The command-line interface is less suitable as the permanent WSS abstraction:

- robust WebSocket send and receive is exposed primarily through libcurl's C
  API
- a persistent bidirectional session needs explicit message and control-frame
  events
- stdout and stderr alone do not provide a clean structured event channel
- credentials and headers need more care than ordinary command arguments
- cancellation, request identity, and multiple live handles need a stable
  lifecycle contract

A direct curl subprocess remains a useful reference backend and an early way
to validate provider request formats. The shared contract must not depend on
curl's command-line output.

## Architecture

```text
agent loop
  |
  +-- provider adapter
  |     builds provider request
  |     parses SSE or provider events
  |     normalizes content, reasoning, tools, usage, and completion
  |
  +-- transport API in Zsh
        start / poll / send / cancel / close
        |
        +-- native-http backend
        |     zsh/net/tcp for local Ollama
        |
        +-- libcurl-helper backend
        |     private Unix socket to an isolated C process
        |
        +-- libcurl-module backend
              zmodload zcoder/curl and call native builtins
```

Provider adapters never call a backend directly. They submit one normalized
request to the transport API and consume normalized transport events. This
keeps a later helper-to-module switch out of the agent loop.

## Zsh transport API

The Zsh-facing functions should use ordinary globals for results, matching the
rest of zcoder, while keeping all handles explicit:

```text
transport_create REQUEST_ID KIND URL METHOD
transport_header HANDLE NAME VALUE SENSITIVE
transport_body HANDLE PAYLOAD
transport_start HANDLE
transport_poll HANDLE
transport_send HANDLE MESSAGE_KIND PAYLOAD
transport_cancel HANDLE REASON
transport_close HANDLE
transport_shutdown_all
```

`KIND` is `http`, `https`, `ws`, or `wss`. The current local backend accepts
only `http`. Hosted backends initially accept `https` and `wss`.

Successful `transport_create` sets:

```text
TRANSPORT_HANDLE
TRANSPORT_BACKEND
TRANSPORT_EVENT_FD
```

Headers and the body are attached before `transport_start` begins network I/O.
This keeps sensitive headers explicit and permits an exact binary body without
constructing one large nested shell value. `TRANSPORT_EVENT_FD` is present for
a helper backend and may be empty for a step-driven module. The TUI can poll
the helper descriptor with `zselect`; a module backend can be advanced through
a nonblocking `transport_poll` call at the same event-loop boundary.

`transport_poll` returns:

| Status | Meaning |
| ---: | --- |
| `0` | One complete event is available in the event globals |
| `1` | No complete event is currently available |
| `2` | The handle reached a clean terminal state |
| `3` | The handle failed; error globals are populated |

An event populates:

```text
TRANSPORT_EVENT_REQUEST_ID
TRANSPORT_EVENT_TYPE
TRANSPORT_EVENT_STATUS
TRANSPORT_EVENT_FLAGS
TRANSPORT_EVENT_PAYLOAD
```

Initial event types:

| Event | Purpose |
| --- | --- |
| `connected` | TLS and protocol negotiation completed |
| `headers` | Final HTTP response status and bounded headers |
| `data` | One HTTP or streaming response chunk |
| `ws_text` | One complete WebSocket text message |
| `ws_binary` | One complete bounded WebSocket binary message |
| `ws_ping` | Peer ping observed when the backend exposes it |
| `ws_pong` | Peer pong observed when the backend exposes it |
| `closed` | Clean HTTP completion or WebSocket close |
| `error` | Classified transport failure |

Provider-level events such as content deltas, reasoning, usage, or tool calls
do not belong here. Those are derived by the provider adapter from `data` or
`ws_text` payloads.

## Helper process design

The proposed helper is a small executable, tentatively `zcoder-curl`. It links
to libcurl and speaks one private protocol to its owning zcoder process.

### Process topology

```text
zcoder foreground
  |
  +-- spawn zcoder-curl with no credentials in argv
  |
  +-- connect to a process-private Unix socket
  |
  +-- exchange framed commands and events
  |
  +-- terminate and reap the exact owned PID on shutdown
```

The socket lives inside `ZCODER_RUNTIME_DIR`, not the shared agent-relay
registry. No other user can enter that directory. The helper accepts exactly
one owning connection and exits when it closes.

A private Unix socket is preferable to Zsh's global coprocess channel, a PTY,
or line-oriented stdout:

- it is full duplex
- it preserves exact binary bytes through ordinary descriptor I/O
- it integrates with `zselect`
- it does not consume the shell's single coprocess slot
- it does not introduce PTY transformations
- it gives the helper one explicit owner and cleanup target

### Framing

The protocol carries a small flat JSON header followed by an optional raw
payload:

```text
ZCODER-CURL/1 <header-bytes> <payload-bytes>\n
<exact JSON header bytes><exact payload bytes>
```

The header is bounded independently from the payload. Proposed defaults:

| Limit | Default |
| --- | ---: |
| Header | 16 KiB |
| HTTP event chunk | 256 KiB |
| WebSocket message | 1 MiB |
| Buffered incomplete input | 2 MiB |
| Live handles | 4 |

Limits must be configurable within conservative hard ceilings. A provider
adapter may impose a smaller limit.

The receiver loops until it has the complete declared header and payload.
Partial reads, partial writes, EOF, timeout, and oversized lengths are distinct
errors. Neither side interprets payload bytes as shell code, patterns, format
strings, terminal escapes, or JSON unless the event consumer explicitly does
so later.

### Commands

Initial commands from Zsh to the helper:

| Command | Purpose |
| --- | --- |
| `open` | Create an HTTPS or WSS handle with method, URL, and policy |
| `header` | Add one literal request header; may be marked sensitive |
| `body` | Attach one exact request-body payload |
| `start` | Begin transfer after configuration is complete |
| `ws_send` | Send one text, binary, ping, pong, or close message |
| `cancel` | Stop one request without stopping the helper |
| `release` | Free a completed or failed handle |
| `shutdown` | Cancel all handles and exit cleanly |

Splitting configuration into bounded commands avoids one large nested request
object and gives sensitive headers an explicit marker. The helper must never
echo a sensitive value in an event or diagnostic.

### libcurl model

The helper should use libcurl's multi interface even if zcoder initially runs
only one model request at a time. That supplies a clean foundation for a WSS
session, cancellation, connection reuse, and future bounded concurrency.

The helper owns all libcurl callbacks and native buffers. It converts callback
activity into framed events only after applying size limits. Zsh never receives
a pointer, libcurl handle, native socket number, or structure layout.

The helper must:

- call global libcurl initialization once
- retain one explicit structure per request ID
- handle partial event writes without interleaving frames
- serialize all output through one queue
- apply backpressure instead of growing without a bound
- automatically answer WebSocket ping according to libcurl's documented
  behavior unless a future policy explicitly changes it
- publish close code and bounded close reason
- classify DNS, connect, TLS, HTTP, timeout, cancellation, protocol, and local
  resource failures separately
- free every easy handle before multi and global cleanup

## Loadable Zsh module design

The research backend would be a real dynamic Zsh module, tentatively named
`zcoder/curl`:

```zsh
module_path=("$ZCODER_HOME/modules/$ZSH_VERSION" $module_path)
zmodload -F zcoder/curl b:zcurl
```

The module links libcurl into the Zsh process and exposes one builtin rather
than mirroring all libcurl options:

```text
zcurl start ...
zcurl header ...
zcurl body ...
zcurl step ...
zcurl send ...
zcurl cancel ...
zcurl release ...
zcurl version
```

Each call completes synchronously and returns quickly. The module must not
start a thread that later calls into Zsh memory. `zcurl step` advances the
libcurl multi handle without blocking, then returns at most one bounded event
through module-owned Zsh parameters:

```text
ZCURL_HANDLE
ZCURL_EVENT_TYPE
ZCURL_EVENT_STATUS
ZCURL_EVENT_FLAGS
ZCURL_EVENT_PAYLOAD
ZCURL_ERROR
```

The Zsh adapter copies those values into the generic `TRANSPORT_*` globals so
provider and agent code cannot distinguish the module from the helper.

### Module lifecycle

The module follows Zsh's native lifecycle:

- `setup_` initializes internal state required before feature discovery
- `features_` and `enables_` publish and control the builtin and parameters
- `boot_` performs remaining visible initialization
- `cleanup_` rejects or safely cancels live handles, removes features, and
  prepares for unloading
- `finish_` releases libcurl global state and all remaining allocations

Cleanup must tolerate partial setup and failed boot. Repeated load, use,
unload, and reload cycles are required tests.

### ABI and packaging cost

A loadable module is coupled to Zsh internals rather than a stable standalone
process ABI. It may require:

- the exact Zsh version's development or generated headers
- matching compile-time configuration and module conventions
- a build for every supported operating system and architecture
- a separate output directory for every `$ZSH_VERSION`
- careful handling of Zsh allocator, parameter, feature, and unload APIs

The current development machine demonstrates this distinction: dynamic module
loading is available, but installable Zsh development headers are not present
by default. libcurl development metadata is available through `pkg-config`.
The module therefore cannot be treated as a universally compilable plugin.

No project directory may be added to `module_path`. A module is executable
native code and must be loaded only from a trusted, user-owned directory that
denies group and other writes.

## Helper versus module

| Concern | Helper process | Zsh module |
| --- | --- | --- |
| Failure isolation | Native crash loses only the worker | Native crash loses zcoder |
| Zsh compatibility | Stable framed protocol | Coupled to Zsh ABI and build |
| Distribution | Normal executable | Per-version module artifact |
| Event integration | Readable Unix-socket descriptor | Explicit nonblocking step call |
| Performance | One local framing copy | Direct in-process buffers |
| Restart | Reap and spawn again | Unload may be unsafe after corruption |
| Debugging | Standalone fixture and sanitizers | Debugger attached to the shell |
| Ambition | Conservative production design | High-value systems experiment |

The process boundary is not expected to matter for model latency. Network and
inference time dominate one local frame copy. A module needs evidence of a
different benefit, such as substantially simpler WSS lifecycle integration,
lower sustained streaming CPU use, or reusable value to the wider Zsh
ecosystem.

## Provider adapters

Transport support alone does not make hosted models interchangeable. A
provider adapter remains responsible for:

- endpoint paths and API versions
- authentication header names
- model identifiers and request options
- system, user, assistant, and tool message mapping
- tool schema and tool-result mapping
- streaming event format
- finish reasons and incomplete responses
- token usage and context metadata
- provider error envelopes and request identifiers

The first adapter should target one documented API shape rather than claim
universal compatibility. An OpenAI-compatible shape may be useful, but
compatibility must be verified per server rather than inferred from its label.

Every adapter converts its stream into the existing agent concepts. The agent
loop must not branch on raw provider event names.

## HTTPS and streaming HTTP

HTTPS should precede WSS because it unlocks ordinary hosted coding turns with
a smaller lifecycle surface. The first implementation should support:

- verified HTTPS POST
- bounded response headers
- complete JSON responses
- chunked or callback-delivered response bodies
- server-sent event parsing in Zsh
- request cancellation by exact handle
- provider request IDs in diagnostics
- explicit response and idle deadlines

SSE parsing remains Zsh logic because it is a textual provider-facing event
format. It must retain partial lines between transport chunks, join multiline
`data:` fields correctly, ignore comments, bound one event, and distinguish
clean completion from truncated EOF.

The current non-streaming Ollama path does not need to change when HTTPS lands.
Streaming should enter the UI only after provider-independent event
normalization is tested separately from curses.

## WSS sessions

WSS is justified when a provider offers material value from a persistent
full-duplex session, such as low-latency incremental interaction, server-driven
events, or conversation state retained on the connection. It is not
automatically better than HTTPS plus SSE for a normal coding turn.

The WSS transport must handle:

- verified HTTPS upgrade and required subprotocol selection
- complete text and binary message boundaries
- fragmented messages
- control frames interleaved with fragmented data
- ping/pong behavior and idle detection
- close codes and reasons
- bounded outbound queues and backpressure
- cancellation distinct from graceful close
- reconnect only when the provider protocol defines safe recovery
- provider session IDs independently from local transport handles

Automatic replay after WSS loss is unsafe by default. The client may not know
whether the server received or acted on the final message. Reconnection and
resumption require provider-specific identifiers or idempotency semantics.

## Credential handling

Secrets may originate from an environment variable or a private configuration
file. Environment variables are convenient but can leak through inherited
process environments on some systems. A file must be real, owned by the
current user, and deny group and other access.

Required rules:

- never place a secret in the helper's argv
- never include it in a request ID, URL, query string, debug record, error,
  transcript, session, or terminal message
- send it only through the private helper connection or an inherited private
  descriptor
- mark sensitive header commands so the helper redacts them structurally
- do not follow redirects with authorization unless the destination is
  explicitly validated as the same trusted origin
- unset temporary Zsh parameters after request construction
- document that Zsh cannot promise cryptographic secure erasure of copied
  parameter storage
- make debug mode omit request headers and bodies by default

The C implementation should minimize secret copies and clear owned native
buffers before freeing them where practical. This reduces exposure but does
not turn a user-space client into a hardened secret vault.

## TLS and URL policy

The hosted transport fails closed unless all of these hold:

- scheme is exactly `https` or `wss`
- URL contains no userinfo
- hostname is non-empty and syntactically valid
- certificate-chain and hostname verification are enabled
- the selected CA source is explicit or comes from libcurl's trusted default
- unsupported TLS or certificate errors are terminal
- response headers and bodies remain within configured bounds

The first release must not expose an insecure-verification switch. Custom CA
files are acceptable when their path is explicitly configured and validated.
Client certificates can be considered later with the same private-file rules.

Redirects should default to disabled for model API calls. If enabled later,
they require a small count limit, loop detection, scheme preservation, and
explicit authorization-header handling.

## Errors and retries

Transport failures need stable categories instead of raw libcurl strings:

```text
configuration
dns
connect
tls
timeout
http_status
protocol
websocket
cancelled
helper_crash
resource_limit
internal
```

The original bounded diagnostic may accompany the category after terminal
sanitization and secret redaction.

Retry policy remains in Zsh. The backend reports whether any request bytes were
sent and whether any response bytes or events were observed. A request may be
replayed automatically only when the provider operation is known to be
idempotent or no request bytes reached the peer. Paid generation requests and
tool-bearing sessions should otherwise report ambiguity to the user.

## Cancellation and shutdown

Cancellation is owned by the Zsh foreground:

1. mark the handle as cancelling
2. send one bounded `cancel` command or call the module builtin
3. stop accepting new events for that request generation
4. wait for a bounded terminal acknowledgement
5. terminate the helper if it does not respond
6. reap the exact owned PID and close every descriptor
7. remove private runtime files and clear partial frame buffers

A helper crash becomes a transport error for every live handle. It must not
leave a request displayed as still running. The application may restart the
helper for a later user turn, but it must not silently replay the failed turn.

The module's cleanup path follows the same logical sequence but cannot provide
process isolation. If native state appears corrupted, attempting clever
recovery inside the same process is worse than terminating cleanly.

## Build and distribution

### Helper

Suggested source layout:

```text
native/
  zcoder-curl/
    main.c
    protocol.c
    protocol.h
    transport.c
    transport.h
```

The build discovers libcurl with `pkg-config` and produces one optional binary.
Possible targets:

```text
make transport-helper
make test-transport-helper
```

zcoder should discover the helper in an explicit configured path or beside its
installed files. It must validate that the binary is a regular trusted file.
The project must not download and execute a binary automatically.

### Module

Suggested research layout:

```text
native/
  zcoder-curl-module/
    curl.c
    curl.mdd
```

Module builds should live outside `lib/`, which is reserved for Zsh source and
`.zwc` wordcode. Build artifacts belong in a versioned directory such as:

```text
build/modules/<zsh-version>/<platform>/zcoder/curl.so
```

The build must verify the running Zsh version and the headers used. A module
compiled for another version is unavailable rather than loaded optimistically.
Failure to build or load it must leave the helper and local Ollama paths intact.

## Implementation phases

### Phase 0: contract spike

- define the Zsh transport functions and event globals
- add a fake backend that emits deterministic partial and complete events
- prove agent and provider normalization without network access
- document lifecycle state transitions

### Phase 1: isolated HTTPS helper

- implement framed helper startup and teardown
- implement verified HTTPS request/response through libcurl
- keep credentials off argv and out of diagnostics
- implement cancellation, deadlines, bounds, and classified errors
- test against a local TLS fixture and one opt-in real endpoint

### Phase 2: streaming provider adapter

- implement SSE parsing independently from the helper
- normalize content, reasoning, tool calls, usage, and finish events
- render incremental output without allowing background terminal writes
- retain exact model history needed for later tool turns

### Phase 3: WSS helper

- add WebSocket open, send, receive, ping/pong, and close commands
- test fragmentation, partial I/O, backpressure, cancellation, and peer loss
- implement one provider adapter only after the transport is stable

### Phase 4: loadable-module spike

- acquire or build against exact Zsh development headers
- expose `zcurl version` and one verified HTTPS operation
- add multi-handle stepping and the shared event globals
- add WSS send and receive
- run load, unload, cancellation, sanitizer, and crash-boundary tests

### Phase 5: promotion decision

Compare the helper and module on:

- correctness across the supported Zsh and operating-system matrix
- startup and steady-state resource use
- streaming CPU cost and latency
- cancellation reliability
- packaging burden
- crash isolation
- code size and auditability
- reusable value outside zcoder

The module becomes a supported backend only if it passes the same behavioral
suite and provides a clear benefit. Novelty alone is not a promotion criterion.

## Test plan

All automatic tests use local fixtures and dummy credentials. Real provider
tests are opt-in and must never run in the ordinary suite.

Framing and process lifecycle:

- partial headers and payloads in both directions
- multiple frames in one read and one frame across many reads
- malformed, negative, overflowing, and oversized lengths
- unexpected EOF and stalled peer
- helper readiness timeout, crash, cancellation, and clean shutdown
- exact PID ownership and descriptor cleanup
- no coprocess, terminal, MCP, relay, or HTTP descriptor leakage

HTTPS and TLS:

- trusted local CA success
- unknown CA, hostname mismatch, and expired certificate rejection
- HTTP status, content length, chunking, and truncated response errors
- response and header size limits
- redirect disabled by default
- authorization not forwarded across an untrusted redirect
- proxy and custom-CA behavior when explicitly configured

Streaming:

- SSE line split at every possible byte boundary
- multiline data fields, comments, blank events, and clean terminator
- Unicode split across transport chunks
- invalid UTF-8 and oversized event rejection
- cancellation during DNS, TLS, headers, and body streaming
- terminal-safe rendering of remote diagnostics

WebSockets:

- successful verified WSS upgrade
- text, binary, empty, and maximum-size messages
- fragmented messages with interleaved control frames
- ping, pong, clean close, protocol close, and abrupt EOF
- partial outbound writes and bounded backpressure
- safe ambiguity reporting after connection loss
- no automatic replay without provider resumption semantics

Credentials:

- secret absent from argv and process listings
- secret absent from debug logs, stderr, transcript, and session files
- unsafe credential-file ownership and permissions rejected
- helper errors structurally redact sensitive headers
- redirect and proxy fixtures cannot capture an authorization header outside
  the configured origin policy

Module-specific:

- wrong Zsh version refuses to load
- feature enable and disable behavior
- repeated load, request, unload, and reload
- cleanup after partial setup and failed boot
- cancellation and unload with active handles
- address, undefined-behavior, and leak sanitizer runs
- helper parity for every transport event and error category

Finish with the normal Zsh checks and full suite:

```sh
make compile
make test
```

## Acceptance criteria

The hosted transport is ready when:

1. Local Ollama behavior remains unchanged when no hosted backend is selected.
2. A verified HTTPS model turn can stream, call tools, continue, and complete
   through the ordinary agent loop.
3. Escape cancels the exact hosted request and reaps all owned resources.
4. API credentials never enter argv, logs, transcripts, or saved sessions.
5. TLS verification failures and ambiguous delivery states fail closed.
6. Provider parsing is independently testable from libcurl and curses.
7. WSS handles fragmentation, control frames, close, and backpressure without
   exposing wire details to the agent loop.
8. Helper failure leaves zcoder alive and able to start a later local turn.
9. The complete ordinary suite passes without network access or credentials.

The module has additional acceptance criteria:

1. It loads only for the exact supported Zsh ABI and from a trusted path.
2. Repeated load/unload and cancellation pass sanitizer and leak checks.
3. It matches the helper's contract and failure classification.
4. It demonstrates enough benefit to justify losing process isolation.

## Open questions

- Which hosted API shape should be implemented first?
- Is HTTPS plus SSE sufficient for the initial hosted-model release?
- Which provider feature creates a concrete need for WSS?
- Should one helper serve all requests or should each active request own a
  helper process?
- Should received WebSocket binary messages be exposed or rejected until a
  provider requires them?
- Which Zsh versions and operating systems can reasonably support the module
  build matrix?
- Is the module valuable enough to become a separately reusable project?
- Should helper and module discovery be compile-time, configuration-based, or
  both?

## References

- [Zsh loadable modules and `zmodload`](https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html)
- [Zsh module development guide](https://github.com/zsh-users/zsh/blob/master/Etc/zsh-development-guide)
- [Zsh native module reference](https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html)
- [libcurl WebSocket interface](https://curl.se/libcurl/c/libcurl-ws.html)
- [curl WebSocket design and status](https://curl.se/docs/websocket.html)
- [libcurl multi interface](https://curl.se/libcurl/c/libcurl-multi.html)

[Documentation index](README.md) · [Architecture](architecture.md) ·
[Safety and permissions](safety.md) · [Development](development.md)

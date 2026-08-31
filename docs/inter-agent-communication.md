# Inter-agent communication

Status: implemented

This document describes the same-host relay that lets one interactive zcoder
instance hand a task to another interactive zcoder instance. The receiving
instance adds the relay to its active conversation and starts a normal agent
turn. Unix-domain sockets are the only transport.

The first release is deliberately a task handoff mechanism, not a distributed
agent framework. It does not discover another machine, share an Ollama request,
stream one instance's transcript into another, or wait for the receiving agent
to finish.

## User experience

Assume two terminals are running zcoder:

```text
user-profiles  pid 42110  /work/app/services/user-profiles
weekly-digest  pid 42302  /work/app/services/weekly-digest
```

In `user-profiles`, the user can say:

```text
Tell the weekly-digest agent that users.name was renamed to
users.display_name and it should update its code.
```

The model first calls `list_agents`, chooses the exact returned instance ID,
and then calls `send_agent_message`. The sender reports that the message was
accepted. In the other terminal, zcoder displays the sender and message, then
runs it through the same agent loop as a local prompt.

Explicit slash commands provide discovery and operator control without asking
the model:

```text
/list-agents
/agents pause
/agents resume
```

`/list-agents` lists live local peers with project label, PID, canonical
workspace, profile, model, state, and short instance ID. It calls the same
discovery function as the model-facing `list_agents` tool but renders the result
directly in the transcript; it never starts an Ollama turn. `/agents` without
an argument shows this instance's relay status and the pause/resume help.
Pausing rejects new deliveries without discarding messages already accepted.
The sidebar or header may show a small queued-message count, but a new modal is
not required for the first release.

## Scope

The initial implementation supports:

- processes owned by the same operating-system user
- processes on the same machine
- interactive, local-mode zcoder instances
- direct request/reply exchanges with an acceptance acknowledgement
- FIFO queuing while the receiver is busy
- the current selected session in the receiving instance
- the existing coding and sysadmin profiles

The initial implementation does not support:

- TCP, SSH, HTTP, VPN, or any other cross-host transport
- relaying through a remote client to its remote server
- headless `--server` or one-shot `--prompt` processes
- completion callbacks or synchronous request/reply waits
- broadcast, agent groups, or automatic fan-out
- forwarding a relayed turn to any instance other than its exact sender
- persistent delivery across receiver shutdown or machine restart

Headless server support can be added later on the server host. A remote client
must never publish itself as an executable peer because its workspace and agent
loop live elsewhere.

## Design principles

1. A relay never bypasses the target's policies. File tools remain confined to
   the target's `ZCODER_WORKSPACE`, and every `run_command` request follows the
   target process's existing approval policy.
2. Sending is user-authorized. The model-facing send tool is only for a user
   request that explicitly asks to contact another zcoder instance. The model
   must not relay merely because another project may be affected.
3. Receiving is ordinary agent work. The transport queues data; it does not
   execute tools or modify conversation state itself.
4. PID and project name are display metadata, not identity. PIDs are reused and
   workspace basenames collide. Selection uses an unpredictable per-process
   instance ID and the exact canonical workspace reported by discovery.
5. The listener never writes to curses. It accepts, validates, acknowledges,
   and spools messages. The foreground process alone updates agent, session,
   and UI state.
6. Delivery and completion are separate facts. An acknowledgement proves that
   the receiver atomically stored the complete message in its process-private
   queue; it does not claim that the agent completed the task.

## Process and module layout

`lib/relay.zsh` loads lazily for eligible interactive local sessions.
It owns discovery, socket framing, the listener worker, the inbox, and tool
dispatch helpers. It must remain testable without curses, Ollama, or the main
agent loop.

The foreground process performs these operations:

```text
state_init
  -> relay_start
  -> ui_init
  -> normal event loop
       -> relay_claim_one
       -> agent_relay_turn, when a message is ready
```

`relay_start` creates a background Zsh listener. The listener owns the
Unix-domain listening descriptor for its full lifetime. This is preferable to
accepting connections from the curses loop: deliveries can still be accepted
while the foreground is waiting for Ollama, running an approved command, or
showing a modal.

The listener worker may only:

- accept a local connection
- read one bounded frame with a deadline
- parse and validate its flat JSON envelope
- atomically write an inbox file
- return one bounded acknowledgement

It must not call `agent_user_turn`, mutate session files, invoke a tool, write
to the terminal, or inherit responsibility for an Ollama request. On shutdown,
the parent terminates and reaps the worker before removing its registry entry
and private spool directory.

## Runtime layout and discovery

The socket and public manifest need a shared, same-user runtime directory.
Choose it in this order:

1. `ZCODER_RELAY_DIR`, when explicitly configured
2. `${XDG_RUNTIME_DIR}/zcoder-agents`
3. `${TMPDIR:-/tmp}/zcoder-${UID}-agents`

Before use, canonicalize the parent and require the relay directory to be a
real directory owned by the current user with no group or other permission
bits. Create it with `umask 077`. Refuse the feature rather than following a
symlink or using a directory with unsafe ownership or permissions.

Use short transport filenames because `sockaddr_un.sun_path` is small and its
limit varies by operating system:

```text
<relay-dir>/a-<pid>-<nonce>.sock
<relay-dir>/a-<pid>-<nonce>.json
```

The socket filename deliberately omits the project name. Project names can
contain arbitrary characters, collide, and make the socket path exceed the OS
limit. The adjacent manifest carries human-readable metadata instead.

Each process also uses its existing private `ZCODER_RUNTIME_DIR` for the spool:

```text
<private-runtime>/relay/
  inbox/
  processing/
  done/
  sequence
  state
```

The instance ID is `<pid>-<nonce>`, where PID comes from
`sysparams[pid]`, not `$$`. The nonce only needs collision resistance; it is not
an authentication secret. Reserve the instance paths with exclusive creation.

Publish the manifest only after the listener has bound the socket and written a
readiness marker. Write it to a private temporary file and rename it into place.
A version-1 manifest is a flat JSON object:

```json
{
  "protocol": 1,
  "instance_id": "42302-18473291",
  "pid": 42302,
  "project": "weekly-digest",
  "workspace": "/work/app/services/weekly-digest",
  "session_id": "1788012120_10392",
  "profile": "coding",
  "model": "qwen3-coder",
  "socket": "/run/user/1000/zcoder-agents/a-42302-18473291.sock",
  "state": "ready",
  "started_at": 1788012102
}
```

The foreground refreshes mutable manifest fields after model or session
changes. Discovery scans only `a-*.json`, bounds the number and size of files,
parses them as data, validates every field, and pings the advertised socket.
Display the canonical workspace so equal project basenames remain
distinguishable.

Do not use `kill -0` as proof of identity. A live PID may have been reused.
Successful protocol ping plus a matching instance ID is the liveness check.
Stale entries fail their protocol ping and are ignored. Discovery never treats
`kill -0` or manifest contents alone as proof that an instance is live.

## Socket protocol

Load `zsh/net/socket` for `zsocket` and `zsh/system` for bounded byte I/O.
`zsocket -l` creates the listener, `zsocket -a -t` accepts without an
unbounded wait, and ordinary descriptor syntax closes accepted descriptors.

Unix stream sockets do not preserve message boundaries. Use one length-prefixed
request and one length-prefixed response per connection:

```text
ZCODER-AGENT/1 <decimal-byte-count>\n
<exact JSON payload bytes>
```

Read the header with a short deadline. Reject a non-decimal length or a payload
larger than `ZCODER_RELAY_MAX_BYTES`, default 65536. Then use `sysread` in a loop
under `setopt LOCAL_OPTIONS NO_MULTIBYTE` until the declared number of bytes is
read. Handle partial reads, EOF, and timeout explicitly. Use
`zcoder_syswrite_all` for the response and close the connection on every path.

The JSON payload stays flat so it can use the existing native parser. A task
delivery has this shape:

```json
{
  "protocol": 1,
  "type": "enqueue",
  "message_id": "42110-18471001-3",
  "target_instance_id": "42302-18473291",
  "sender_instance_id": "42110-18471001",
  "sender_pid": 42110,
  "sender_project": "user-profiles",
  "sender_workspace": "/work/app/services/user-profiles",
  "body": "users.name was renamed to users.display_name. Update consumers and verify the focused tests.",
  "created_at": 1788012245
}
```

The listener validates the target ID, message ID grammar, field types, body
length, sender metadata length, and protocol version. Sender metadata is useful
context, not trusted proof. The private relay directory limits ordinary access
to the same UID, but another process running as that UID can forge a request.
Portable peer-credential authentication is outside the Zsh-first MVP.

Acknowledgements are framed flat JSON objects:

```json
{"protocol":1,"type":"ack","message_id":"42110-18471001-3","status":"accepted","queue_position":1}
```

Defined statuses are:

| Status | Meaning |
| --- | --- |
| `accepted` | Atomically stored in the receiver inbox |
| `duplicate` | The same message ID was already accepted |
| `paused` | The receiver is live but not accepting new work |
| `full` | The bounded receiver queue has no capacity |
| `invalid` | The frame or envelope failed validation |
| `wrong_target` | The instance ID does not match the listener |
| `unsupported` | The protocol version or message type is unknown |

The sender uses bounded writes and a short acknowledgement read deadline, then
reports the exact status as the tool result. It may retry once with the same
message ID after an ambiguous transport failure. It must not create a new ID
for that retry.

## Queue and delivery semantics

The default maximum queue depth is 16. Accepted envelopes move through three
directories:

```text
inbox -> processing -> done
```

The single listener assigns a monotonically increasing sequence and publishes
`inbox/<sequence>-<message-id>.json` with temporary-file-plus-rename semantics.
The foreground atomically renames the oldest inbox entry into `processing`
before parsing it again. After the agent turn ends, it removes the processing
payload and retains an empty receipt marker in `done` for the receiver process
lifetime. Those small markers make ambiguous sender retries idempotent without
retaining task text. Invalid spool data is quarantined and shown as an error
rather than entered into the model context.

The guarantee is at-most-once execution after acknowledged enqueue within the
receiver process lifetime:

- `accepted` means the complete envelope is in the receiver's private spool.
- A sender timeout is ambiguous; retrying the same ID resolves it safely.
- A receiver crash may lose accepted but unprocessed messages.
- Messages do not survive deliberate receiver shutdown or machine restart.
- Agent success or failure is not returned to the sender in version 1.

Messages are processed FIFO, one turn at a time. If a local user turn is
running, the listener continues to enqueue but the foreground waits until that
turn ends. Before accepting the next keyboard submission, the main loop claims
one queued relay and starts it in the session selected at claim time. Polling
the queue before reading the next input event makes session selection and relay
claiming deterministic in the foreground and prevents concurrent mutation of
`AGENT_MESSAGES`, UI arrays, or session files.

Pausing changes listener state to reject new envelopes with `paused`. Already
accepted messages remain queued and resume in FIFO order.

## Model-facing tools

Add two independently testable built-in tools when the relay is available.

### `list_agents`

No arguments. It returns live same-user instances other than the caller. Each
record includes the exact `instance_id`, project, canonical workspace, PID,
profile, model, and observed state. Results are bounded and sorted by project,
then PID.

### `send_agent_message`

Arguments:

```json
{
  "target_instance_id": "42302-18473291",
  "message": "Update weeklyDigest.ts for users.display_name and run its focused tests."
}
```

The target must be an exact live ID returned by discovery; project label or PID
alone is rejected as ambiguous. The message is bounded, must be non-empty, and
is sent as literal data without evaluation.

Its tool description and system guidance must state:

- call it only when the current user explicitly requested communication with
  another zcoder instance
- send the smallest self-contained task and relevant facts
- do not claim the target completed anything after an `accepted` response
- do not include secrets or unrelated transcript history

During a relay-originated turn, expose `send_agent_message` only as a reply path
to that turn's exact sender instance. Dispatch must independently enforce the
same target restriction. This permits multi-message A↔B exchanges while still
blocking forwarding, fan-out, and model-created agent swarms. `list_agents` may
remain available for diagnosis, but it does not expand the reply authority.

## Slash-command discovery

`/list-agents` is the user-facing, read-only equivalent of the `list_agents`
tool. Route both through one `relay_discover` function so liveness checks,
sorting, stale-entry handling, and output bounds cannot drift between the UI and
model paths.

The command excludes the current instance and displays one peer per row:

```text
PROJECT          PID    STATE   INSTANCE ID       WORKSPACE
weekly-digest    42302  ready   42302-18473291    /work/app/services/weekly-digest
```

Control bytes are rendered visibly before they reach curses. When no peers are
available, the command returns a normal informational message rather than an
error:

```text
No other local zcoder instances are available.
```

If relay support is disabled or unavailable, report that state and its known
reason. In remote-client mode, explain that discovery is local to the machine
running the agent and is not bridged through the client. `/list-agents` performs
only local socket pings, does not call Ollama, and remains usable while Ollama
is unavailable.

## Receiving an agent turn

Refactor `agent_user_turn` so user-origin setup and the common execution loop
are separable. A normal local prompt keeps its current behavior. A relay uses a
new `agent_relay_turn` entry point that:

1. appends a visible `relay` transcript event with sender project, PID, and
   workspace
2. adds a labelled user-role context record with `agent_add_context_message`
3. does not append the relay body to `AGENT_USER_MESSAGES`
4. does not use the relay text to title a new session
5. limits the send tool to the exact sender for the duration of that turn
6. runs the same prepare, Ollama, tool, completion, loop-detection, and
   persistence path as a local user turn

The context record should use a fixed wrapper generated by zcoder:

```text
<agent_relay>
This task was relayed at the local user's request by another zcoder process.
Sender: user-profiles (pid 42110)
Sender workspace: /work/app/services/user-profiles

Task:
users.name was renamed to users.display_name. Update consumers and verify the
focused tests.
</agent_relay>
```

The system prompt defines relay records as work requests, not evidence. The
receiving model must inspect current workspace state before relying on a claim
about a file or change. Relay text cannot weaken project instructions,
workspace confinement, approval policy, or the sysadmin safeguards.

The `relay` UI role should render distinctly from both the local `user` role and
ordinary `system` notices. Persist it in session UI events so resuming the
session explains why the autonomous turn occurred. The model history retains
the labelled user-role context because Ollama templates require a single
leading system message.

## Lifecycle and failure handling

Startup:

1. confirm local interactive mode and relay configuration
2. initialize the existing process-private runtime directory
3. validate or create the shared same-user relay directory
4. create spool directories with mode 0700
5. spawn the listener and wait for a bounded readiness signal
6. publish the manifest atomically
7. enable the tools only after readiness succeeds

If socket support or safe runtime storage is unavailable, zcoder continues
without inter-agent tools and shows one concise warning. The feature must not
make ordinary startup fail.

Shutdown:

1. mark the instance unavailable and remove its manifest
2. terminate and reap the owned listener PID
3. unlink only the exact socket path owned by this instance
4. close descriptors
5. let `zcoder_runtime_cleanup` remove the private spool

Cleanup is idempotent and validates the expected relay root, filename grammar,
instance ID, ownership, and file type before unlinking. It never recursively
removes the shared relay root.

The listener uses the actual child PID from `sysparams[pid]`. Parent and worker
traps must not kill by command name or assume `$$` identifies the child. Every
accepted descriptor is closed in an `always` block. Background processes must
not retain unrelated listener, HTTP, MCP, or terminal descriptors.

## Configuration

Settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `ZCODER_RELAY` | `on` | `on`, `off`, or `paused` for eligible local interactive instances |
| `ZCODER_RELAY_DIR` | unset | Override the validated same-user registry directory |
| `ZCODER_RELAY_MAX_BYTES` | `65536` | Maximum framed request or response size |
| `ZCODER_RELAY_MAX_MESSAGE_CHARS` | `16000` | Maximum relayed task text |
| `ZCODER_RELAY_MAX_QUEUE` | `16` | Maximum accepted, unfinished messages |
| `ZCODER_RELAY_IO_TIMEOUT` | `2` | Frame and acknowledgement deadline in seconds |

Invalid values fail closed for the relay feature and do not alter core command
or workspace policy. A future `--agent-name` option may add a friendly label,
but project basename, PID, short ID, and canonical workspace are sufficient for
the first release.

## Implementation map

### Phase 1: transport and registry

- add the optional `zsh/net/socket` capability check
- implement safe shared-directory validation
- implement manifest publication, discovery, ping, and stale-entry handling
- implement bounded framing, exact byte reads/writes, acknowledgement parsing,
  and listener cleanup
- implement atomic FIFO spool and duplicate detection
- add pure transport tests before UI integration

### Phase 2: agent and session integration

- split origin-specific setup from the common body of `agent_user_turn`
- add `agent_relay_turn` without changing exact-user ledger semantics
- add the persisted `relay` UI role
- update the main TUI loop to claim one queued relay before keyboard submission
- update manifest data after model and session changes
- add pause/resume and graceful listener shutdown

### Phase 3: tools and documentation

- add `list_agents` and `send_agent_message` schemas and dispatch
- add `/list-agents` as the direct UI adapter over `relay_discover`
- expose the send tool only during a local-user-originated turn and when the
  relay is available
- add model instructions covering authorization and delivery semantics
- document `/list-agents` and `/agents pause|resume` in the interface guide and
  relay safety in the safety guide
- update architecture and configuration references

## Test plan

All tests use temporary private roots and must not depend on a user's real
runtime directory.

Transport and framing:

- ping and enqueue between two isolated Zsh processes
- partial header, partial payload, partial write, EOF, and stalled peer
- empty, malformed, oversized, unsupported, and wrong-target frames
- spaces, tabs, newlines, quotes, backslashes, glob characters, and Unicode
- byte counts under multibyte locales
- exact descriptor closure on success, error, timeout, and shutdown

Discovery and safety:

- two workspaces with the same basename remain distinguishable
- `/list-agents` and the `list_agents` tool use the same exact discovery records
- `/list-agents` excludes the caller, handles no peers, and performs no Ollama
  request
- stale manifest, stale socket, PID reuse, missing socket, and malformed JSON
- unsafe ownership, permissions, symlinked roots, symlinked manifests, and
  overlong socket paths fail closed
- discovery bounds file count and manifest size
- cleanup removes only the current instance's exact files

Queue semantics:

- busy receiver accepts and later processes messages FIFO
- duplicate message IDs execute no more than once
- queue limit, pause/resume, sender timeout, receiver exit, and listener crash
- one queued message is claimed atomically by only one foreground path
- a relayed turn can reply only to its exact sender and cannot target a third agent

Agent integration:

- relay content enters model context but not `AGENT_USER_MESSAGES`
- relay content does not set the session title
- visible relay events persist and reload
- existing file confinement and `run_command` approval remain unchanged
- Escape cancels the active receiving turn without corrupting later queue items
- local prompts and warm-up behavior remain unchanged when relay is disabled

Run `zsh -f -n` for every changed Zsh file and finish with the required full
suite:

```sh
make test
```

## Acceptance criteria

The feature is ready when:

1. Two local interactive instances owned by the same user discover each other
   without configuration.
2. `/list-agents` displays the other live instances without invoking Ollama.
3. The sender can select an exact instance and receive an unambiguous delivery
   result.
4. A busy receiver queues the message and starts it after its current turn,
   without concurrent mutation of agent or session state.
5. The receiving transcript clearly identifies the relay source and persists
   it across session reload.
6. Relayed work uses the target's normal workspace, project instructions,
   tools, command approval, cancellation, completion, and verification paths.
7. Malformed, oversized, duplicate, stale, unsafe, and cross-instance requests
   fail closed.
8. Disabling or losing socket support leaves ordinary zcoder operation intact.
9. The complete test suite passes on Zsh 5.8 and newer.

[Documentation index](README.md) · [Architecture](architecture.md) ·
[Safety and permissions](safety.md) · [Development](development.md)

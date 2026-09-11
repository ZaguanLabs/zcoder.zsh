# Steering and queued follow-ups

Starting in 0.12.0, you can send another message while zcoder works.

| Control | When the message reaches the model |
| --- | --- |
| Enter during an active turn | After the current response and its complete tool batch, before the next model request |
| Ctrl+G during an active turn | After the current task finishes |
| `! command` with Enter or Ctrl+G | Executes after the current task finishes; output enters context without a model response |
| Shift+Enter or Alt+Enter | Inserts a newline without sending |

The interface confirms acceptance and clears the editor. The message appears
as a user entry when the agent consumes it. Steering does not interrupt a
response, cancel a command, or skip an outstanding tool call. A completed
response without tools can also receive steering before the agent returns.
Input arriving during goal verification is held until that verification returns;
pending steering defers acceptance of the candidate completion.

A queued `!` command also holds later requests behind it, including messages
submitted with Enter. Those requests can then use its output. Shell commands
follow the same approval policy as `run_command`; see
[user shell commands](user-shell-commands.md).

Slash commands remain idle controls. Standalone model loading, compaction,
consultations, and other activity without an active conversation turn retain
an unsent draft. Command and external-action approval dialogs retain their own
controls and policies.

## Cancellation and recovery

Escape stops active work and preserves the unsent draft. Accepted but
unconsumed messages remain with the saved session after cancellation, an error,
or process restart. They do not run automatically when you start a different
turn. Select the original session, then use:

```text
/queue
/queue resume
/queue drop MESSAGE_ID
```

Listing shows each pending message's ID, delivery mode, and text. Resume
processes pending messages in arrival order. Drop discards an unconsumed
message; it cannot undo a message already added to history or any tool effects.
There is no automatic retry of a cancelled model request.

Shell execution is claimed before starting the command. If the process stops
before its result is saved, resuming reports the interruption and possible
side effects without repeating the command. Submit it again explicitly to retry.

## Remote HTTP API

This is zcoder's own API, separate from Ollama. Remote protocol remains **1**.
Check for boolean `input_queue: true` in `GET /v1/hello` before enabling
these controls. Older servers omit the field; clients must retain draft-only
behavior. The existing `POST /v1/turn` still rejects a second active turn with
409. Use its `turn_id` receipt for input admission, including a turn waiting
for model warm-up.

Every request below requires the normal bearer token. Bodies are flat JSON
objects. The selected session's ID comes from the session API.

```http
POST /v1/input
Authorization: Bearer TOKEN
Content-Type: application/json

{"session_id":"1700000000_12345","turn_id":"1700000100_4321","message_id":"client-message-1","mode":"steer","text":"Please also check the retry path."}
```

Success returns HTTP 200:

```json
{"message_id":"client-message-1","state":"accepted"}
```

| Endpoint | Body fields | Successful response |
| --- | --- | --- |
| `POST /v1/input` | `session_id`, `turn_id`, `message_id`, `text`; optional `mode` | Receipt |
| `POST /v1/input/status` | `session_id`, `message_id` | Receipt |
| `POST /v1/input/list` | `session_id` | `{"turn_id":"…","pending":"[ID] mode: text\n…"}` |
| `POST /v1/input/drop` | `session_id`, `message_id` | Discarded receipt |

The default mode is `steer`; `follow_up` waits for task completion.
The list response's `turn_id` identifies accepting work, or is empty when
admission is closed. `pending` is display text, not a structured message array;
use status with your own IDs to reconcile submitted messages.
To recover pending input, select the session while idle and submit
`{"prompt":"/queue resume"}` through `POST /v1/turn`. Poll its normal events.

Message IDs must contain 1–64 ASCII letters, digits, underscores, or hyphens.
Text must contain 1–65,536 UTF-8 bytes. Storage allows 100 pending messages and
1,000 total receipts per session; start a new session after the receipt limit.

Receipts have three states: `accepted`, `consumed`, and `discarded`.
Consumption means the message has been added to saved conversation history;
it does not mean that the model has answered it. Repeating an identical
submission with the same ID returns its current receipt, even after completion.
Reusing an ID with different text, mode, or turn ID returns 409.

A stale turn, exhausted queue, unknown receipt, or unavailable queue also
returns 409. Malformed JSON or non-string fields return 400. A session outside
the server's workspace/profile returns 404. Authentication remains 401.
After a timeout, retry with the same ID and exact submission or query status.
Do not generate a new ID for an uncertain retry.

Consumption uses the existing `message` event with `role: "user"`. No new
event types are introduced. One `complete` event closes the run after its
follow-ups finish. Normal final closure and publication share the queue lock,
so newly accepted input cannot slip past a successful conversation completion.
Failed or cancelled work leaves unconsumed receipts pending for recovery.

## ACP extension

ACP protocol also remains **1**. Clients can opt into the namespaced
`_zcoder/input` method when initialization advertises:

```json
{"agentCapabilities":{"_meta":{"zcoder/inputQueue":true}}}
```

This object is an excerpt of the initialization response. Standard
`session/prompt` continues to allow one active prompt. The extension responds
independently while that prompt remains active.

```json
{"jsonrpc":"2.0","id":20,"method":"_zcoder/input","params":{"sessionId":"1700000000_12345","action":"list"}}
```

The result uses the same flat `turn_id` and `pending` fields as HTTP. Use
that run ID in the submission:

```json
{"jsonrpc":"2.0","id":21,"method":"_zcoder/input","params":{"sessionId":"1700000000_12345","action":"submit","turnId":"1700000100_4321","messageId":"client-message-1","mode":"steer","text":"Please also check the retry path."}}
```

Supported actions are `submit` (the default), `status`, `list`, and `drop`.
They use `sessionId`, `turnId`, and `messageId` in parameters; receipt results
retain the HTTP `message_id` and `state` spelling. Status and drop need only
the session and message IDs. Invalid parameters return JSON-RPC -32602;
queue conflicts return -32000. A consumed message produces the existing
`user_message_chunk` session update. The original prompt result waits for
follow-ups as well.

For recovery, send a normal `session/prompt` containing `/queue resume`
after loading the original session. ACP over `--connect` forwards queue
operations to the remote server and advertises support only when that server
supports the extension. Generic ACP clients need to implement this extension
to expose steering controls.

## Implementation

`lib/input_queue.zsh` stores private records beneath
`<session>.session/input_queue/`. An OS-backed `zsystem flock` serializes
publication, consumption, discard, and admission closure. Temporary records
are renamed atomically. Only the conversation owner drains the queue; HTTP and
ACP brokers never modify their own copies of `AGENT_MESSAGES`.

The owner saves a user message with an internal input ID before publishing its
consumed receipt. Recovery checks that ID to avoid duplicating a message if the
process died between those steps. The model serializer removes this metadata.
This is process-restart recovery, not a power-loss durability guarantee.
The implementation uses native Zsh modules and does not add a runtime dependency.

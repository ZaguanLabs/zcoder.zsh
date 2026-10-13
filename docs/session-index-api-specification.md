# Session browsing API specification for client integrations

Status: implemented in zcoder.zsh v0.20.4 (`61f6ab3`), deployed on 2026-10-05.
Audience: maintainers of API clients, including zweb.

This specification describes the persistent session index introduced in
v0.20.4 and the existing session behavior clients must preserve when using it.
The index reduces the work required to enumerate saved conversations. The
protocol remains version 1, with the same endpoints, JSON fields, authentication,
and one-record pagination. Existing clients need no index-specific migration.

The empty-conversation filtering introduced in v0.20.3 has a separate client
impact: a selected empty session may be absent from the conversation list.
Clients must keep selection separate from list membership.

For the wider protocol, see the
[remote API specification](remote-access-system-specification.md). This document
clarifies session behavior for v0.20.4 where the older baseline differs.

## Changes and compatibility

| Area | Behavior in v0.20.4 | Client consequence |
| --- | --- | --- |
| Saved conversation discovery | Uses a persistent index when valid, otherwise rebuilds or scans | Faster discovery without a new request format |
| Empty conversations | Hidden when agent, visible-event, and user-ledger counts are all zero | An empty list does not imply there is no selected session |
| List pagination | One item per request; each request refreshes the list | Cursors still describe positions in a changing list |
| Transcript reads | Use the existing locked session snapshot and event files | No event-read batching or transcript acceleration guarantee |
| Turn events | Use the existing transient event directory | Keep turn-event cursors separate from history cursors |
| Handshake | Still advertises `protocol: 1` and `sessions: true` | No index capability flag or version field was added |

The index is private server storage. Clients must use the HTTP API rather than
read, parse, or maintain `.sessions.index` themselves. It does not provide an
HTTP ETag, a snapshot token, a delta feed, or a bulk-list endpoint.

## Session listing contract

Request:

```http
GET /v1/sessions?after=0
Authorization: Bearer <configured-token>
```

The server filters sessions by its canonical workspace and profile, orders
them by descending saved activity time, and returns the item at position
`after + 1`. An invalid or missing saved activity timestamp uses the timestamp
portion of the session ID internally. Clients should preserve server ordering
and treat session IDs as opaque.

Example response, HTTP 200:

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

| Field | Type | Meaning |
| --- | --- | --- |
| `event` | string | `session`, or `none` at the tail |
| `seq` | number | One-based list position; pass it as the next `after` |
| `id` | string | Session identity, used for selection and transcript requests |
| `title` | string | Saved display title |
| `model` | string | Model recorded with the saved session |
| `current` | number | `1` if selected by this named server, otherwise `0` |
| `empty` | number | `1` if both agent-message and visible-event counts are zero |

At the tail the response is HTTP 200 with `{"event":"none"}` and no `seq`.
For this endpoint, `after` must be a decimal non-negative integer; invalid
values return HTTP 400. The response does not expose generation paths, counts,
workspace, profile, or `updated_at` as new list fields.

The list's inclusion rule also considers the exact-user ledger. A ledger-only
session can therefore be listed with `empty: 1`. Clients should not apply
`empty: 1` as an additional blanket filter.

### Enumeration and consistency

Start at `after=0`, collect each `session` response, advance to its `seq`, and
stop at `none`. Require a strictly advancing sequence. Use session ID as the
row identity rather than sequence number, and deduplicate IDs within a refresh.

Each HTTP request refreshes the list independently. A session saved between
requests may move toward the beginning; positions can shift and an enumeration
can repeat or miss an item. The index does not freeze ordering across requests.
Deduplication handles repeated items; a later refresh from zero reconciles
items that moved behind an already-consumed cursor.

Recommended zweb behavior is to stage a replacement list and publish it after
reaching `none`. Retain the previous list if a request fails. Refresh from zero
after a completed turn, reconnect, or explicit user refresh. Avoid enumerating
the whole list on every turn-event poll.

## Selected sessions and empty drafts

`POST /v1/session/new` with `{}` returns HTTP 200 and an object containing the
new `id`. The server persists an empty identity and selects it. Because all
three conversation counts are zero, that identity is initially absent from
`GET /v1/sessions`. Once saved conversation content exists, it becomes eligible
for listing.

A client creating a session must retain the returned ID as its selected draft.
It can fetch `/v1/session?id=ID&after=0`; an untouched transcript returns
`{"event":"none"}`. It must not interpret absence from the list as creation
failure, deletion, or permission denial, and must not retry creation merely
because the list omitted the new ID. Creation has no idempotency guarantee.

There is a known mismatch in the bundled client helpers:
`remote_client_new_session()` refreshes the list and requires the new ID to
appear with `current: 1`. Under the empty-session rule, that check can report
`server selected a different session` after successful creation. zweb should
use the successful creation response as the selection acknowledgement rather
than copy that list-based check. This specification documents the mismatch;
v0.20.4 did not repair those helpers.

For a saved conversation, select it with:

```http
POST /v1/session/select
Authorization: Bearer <configured-token>
Content-Type: application/json

{"id":"1788012120_10392"}
```

Success is HTTP 200 with `{"ok":true}`. Missing or inaccessible IDs return
404. Selection and creation return 409 while a turn is active or queued.

Selection belongs to the named server, and another connected client can change
it. `POST /v1/turn` uses the server's selected session; its current request
contract does not bind a prompt to a client-supplied session ID. Retaining a
draft ID locally does not provide exclusive ownership of server selection.
For an empty selection, the list alone cannot prove which session is selected.

## Transcript and turn-event cursors

Transcript request:

```http
GET /v1/session?id=1788012120_10392&after=0
```

Preserve the literal query order, `id` followed by `after`. Each HTTP 200
response contains one visible `message` with `seq`, `role`, `content`,
`thinking`, `time`, `reasoning_open`, and `metadata`, or `{"event":"none"}`.
`metadata` is a string; clients should preserve it and use the existing
transcript metadata contract. Missing or out-of-scope sessions and invalid
transcript IDs or cursors return 404.

Each request reads one committed generation under the session read lock.
Referenced records remain protected through the read, including records reused
from older generations. Multiple requests are separate snapshots: this is
not a transaction covering the complete transcript. Stage a replacement
transcript before swapping it into the UI, especially when changing sessions.

Use three separate cursor domains:

| Cursor | Scope | Reset rule |
| --- | --- | --- |
| Session-list `after` | One enumeration of one endpoint's conversation list | Zero for every full list refresh |
| Transcript `after` | One endpoint and one session's visible history | Zero when loading or replacing that session's transcript |
| Turn-event `after` | One endpoint's current turn stream | Zero after a turn is accepted |

`GET /v1/events?after=N` remains short polling. It returns the first current-turn
event after `N`, or `none` when no later event currently exists. A `none` turn
event does not mean the turn has finished. Event sequence numbers restart for
each accepted turn; the event files are cleared when a new turn starts and
when the server initializes. Restore saved history through the transcript API
after reconnecting rather than treating the transient stream as durable replay.

For a client connecting to multiple hosts, key local records by endpoint and
session ID. Keep polling state per endpoint and per turn; session IDs or cursor
positions alone are not a cross-host namespace.

## Server index implementation

The index lives at `$ZCODER_SESSIONS_DIR/.sessions.index`. Its first line is
`zcoder-sessions-v1`. Each following line contains ten canonically shell-quoted
fields: ID, generation name, workspace, profile, activity timestamp, title,
model, agent-message count, visible-event count, and user-ledger count.
Parsing uses Zsh lexical splitting and quote removal, without sourcing or
evaluating stored data.

Readers check the format, IDs, duplicate entries, committed generation markers,
generation directories, and directory membership before accepting the index.
Each `current` marker is a regular file containing a generation name.
Generation changes, imported session directories, and directory deletions
invalidate the cached listing.

On a valid index, listing reads its consolidated metadata and each session's
generation marker, then filters and sorts in Zsh. It avoids the previous eight
metadata reads and snapshot lock for every discovered session. The API then
still reads four fields under a snapshot lock for the single row it returns:
agent-message count, visible-event count, title, and model.

### Publication and failure recovery

Writers acquire `.sessions.lock` before the session's `save.lock`. The shared
index lock serializes writers to different sessions as well as index rebuilds,
preventing one whole-file replacement from losing another session's update.
Both lock acquisitions use the existing five-second timeout convention.

The save sequence is:

1. Prepare a complete session generation under the locks.
2. Remove the previous index before publishing the new `current` marker.
3. Publish `current` by atomic rename.
4. If the previous index was valid, update that session's entry and publish
   the replacement index by temporary-file rename. An initially empty store
   can also publish its first index during the save.
5. Release the locks.

A process killed between steps 3 and 4 leaves a committed session and a cache
miss. Failure to write the replacement index does not fail an already committed
save. Invalidation must succeed before publication; failure at that stage
prevents the session commit.

When the index is missing, malformed, or stale, listing attempts a locked
rebuild from session snapshots. If rebuilding is unavailable, it uses the
original scan. Saves do not rebuild an invalid index by scanning unrelated
sessions: that previously delayed quitting behind an unrelated writer lock.

Legacy histories without immutable generation markers use the scan fallback.
A legacy or unreadable session can prevent a complete index rebuild, so the
fast path is not guaranteed for every store. Rebuilds and fallback scans can
also wait on locks. Clients should retain normal request timeouts and retry
behavior rather than assume all listing responses are immediate.

## Performance bounds

A local synthetic fixture with 200 generation-backed sessions and ten repeated
listings averaged approximately 14 ms using the index versus 28 ms using the
original scan. This measured `state_refresh_sessions_list()`, with the fixture
already created and the index primed. It excluded HTTP transport, round trips,
JSON response construction, the API's selected-row snapshot reads, and zweb
rendering. It is an observation, not a latency target.

Listing still performs work proportional to stored session count, plus sorting.
One-item HTTP pagination also remains: enumerating `n` returned conversations
requires `n + 1` requests, and each refresh checks the stored sessions again.
The release reduces filesystem work; it does not make full enumeration O(1).
Transcript record reads and transient event-directory scanning remain unchanged.

## Deployment and client verification

The v0.20.4 release was deployed to fidelity, bluebox, spiffle, bsd, and knas,
and to these six local services. Existing models, profiles, workspaces, token
files, and launcher command policies were preserved.

| Named local server | Port |
| --- | ---: |
| `spurven-sysadmin` | 1337 |
| `zweb-coding` | 1338 |
| `zcoder-coding` | 1339 |
| `scout-coding` | 1340 |
| `giggin-coding` | 1341 |
| `logme-code` | 1343 |

Deployment checks confirmed HTTP 401 for unauthenticated status requests on
every updated endpoint. All six local user-service units remained
`active (running)` on a repeated check more than 20 seconds later. This verifies
listener availability and authentication enforcement, not a complete zweb
workflow or model turn.

For zweb, verify the following against its configured endpoint:

- Enumerate from zero to `none`, preserving server order and deduplicating IDs.
- Keep a newly created ID selected even while it is absent from the list.
- Select and load a saved conversation without mixing its transcript with a
  previously selected conversation or another host's state.
- Advance only the cursor belonging to the response's endpoint and stream.
- Reset the turn cursor after acceptance and reload saved history on reconnect.
- Preserve the existing list and transcript if a refresh fails; handle 401,
  404, and 409 through the existing authentication and session flows.

Server validation passed `make compile` and all 3,907 full-suite assertions.
Index regression coverage includes cache hits without session snapshots,
multiline quoting, malformed and missing indexes, external generation changes,
directory deletion, concurrent saves, optional index-write failure, and a
process killed between session and index publication.

## Implementation references

- [Session storage and index](../lib/state.zsh)
- [Session summaries, transcripts, and turn events](../lib/remote_server_agent.zsh)
- [HTTP dispatch and server lifecycle](../lib/remote_server.zsh)
- [Bundled client pagination and selection](../lib/remote_client.zsh)
- [State and index regression tests](../tests/hardening_state.zsh)
- [Operator guide](remote.md)

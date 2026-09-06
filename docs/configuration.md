# Configuration and context management

Command-line flags configure a single process. Most defaults can also be set
with environment variables, which is useful for a preferred model, profile, or
context policy.

Run `./zcoder.zsh --help` for the complete CLI reference.

## Core defaults

| Setting | Default | Purpose |
| --- | --- | --- |
| `ZCODER_MODEL` | `qwen3-coder:latest` | Ollama model |
| `OLLAMA_HOST` | `localhost:11434` | Ollama endpoint |
| `ZCODER_PROFILE` | `coding` | `coding` or `sysadmin` prompt |
| `ZCODER_COMMAND_POLICY` | `ask` | `ask`, `allow`, or `deny` |
| `ZCODER_THINK` | `true` | Request model reasoning |
| `ZCODER_STREAM` | `true` | Stream eligible local interactive responses; `false` retains buffered responses |
| `ZCODER_WARMUP` | `true` | Warm the selected model and stable prompt context before interactive work |
| `ZCODER_TOOL_EXPOSURE` | `full` | `full` exposes all tools immediately; experimental `staged` routes before exposing tools |
| `ZCODER_HTTP_READ_TIMEOUT` | 900 | Idle seconds allowed while waiting for Ollama response data |
| `ZCODER_MAX_TOOL_OUTPUT` | 32768 | Maximum returned tool-output characters |
| `ZCODER_MAX_OUTPUT_TOKENS` | 8192 | Maximum tokens requested from a normal model turn |
| `ZCODER_HOME` | `${XDG_CONFIG_HOME:-$HOME/.config}/zcoder` | User configuration and sessions |

Command-line values take precedence where an equivalent flag exists.

## Tool exposure

The default `full` mode preserves the single-phase agent loop. Experimental
`staged` mode starts each ordinary user turn with a short, non-thinking,
structured routing request. This request has no native `tools` field and
classifies the requested outcome as `respond`, `workspace`, or `external`.
`respond` returns the complete answer immediately. `workspace` admits core
workspace tools and non-external MCP capabilities. `external` is reserved for
an explicitly requested, externally visible write through a named destination.

A direct response ends the turn without entering the agent loop. A workspace
decision withholds inter-agent delivery and MCP tools classified as external
writes. An external decision exposes those capabilities, but each externally
visible MCP mutation still requires one explicit confirmation at dispatch. The
router itself performs no operation, and the dispatcher rejects a native tool
call emitted during routing. Shell command approval and workspace confinement
remain separate, unchanged boundaries.

Enable staged exposure for one run with:

```sh
./zcoder.zsh --tool-exposure staged
```

or set `ZCODER_TOOL_EXPOSURE=staged`. Goal workers and relayed turns continue
to receive full tool exposure because they already represent explicit agentic
work. The three outcomes describe authority classes rather than individual
tools, keeping tool vocabulary out of the routing request while separating
ordinary workspace work from externally visible side effects.

## Local agent relay

The relay is enabled by default for local interactive sessions. It is not
started for one-shot, remote-client, or remote-server processes.

| Setting | Default | Purpose |
| --- | --- | --- |
| `ZCODER_RELAY` | `on` | `on`, `off`, or `paused` |
| `ZCODER_RELAY_DIR` | unset | Override the private same-user registry directory |
| `ZCODER_RELAY_MAX_BYTES` | `65536` | Maximum framed request or response bytes |
| `ZCODER_RELAY_MAX_MESSAGE_CHARS` | `16000` | Maximum relayed task characters |
| `ZCODER_RELAY_MAX_QUEUE` | `16` | Maximum accepted unfinished messages |
| `ZCODER_RELAY_IO_TIMEOUT` | `2` | Frame and acknowledgement deadline in seconds |

The registry defaults to `${XDG_RUNTIME_DIR}/zcoder-agents` when available,
then `${TMPDIR:-/tmp}/zcoder-${UID}-agents`. It must be a real directory owned
by the current user with no group or other permission bits. Invalid settings or
unavailable Unix-socket support disable only the relay; ordinary local work
continues. `/agents` reports the current state and `/list-agents` lists peers.

## Model warm-up

The local TUI starts with a `[ Warming Up ]` badge and sends a disposable,
non-thinking Ollama request containing the resolved system prompt, project
instructions, Skill context, MCP routing, and tool schemas. Its response is
captured silently and never enters the transcript, model history, compaction
ledger, or saved session. A successful response changes the badge to
`[ Ready ]`.

The prompt editor remains usable during warm-up. Submitting real work before it
finishes cancels the disposable request and immediately starts the real turn.
Changing the model, host, session, Skills, or MCP configuration starts a fresh
warm-up for the effective context.

Use `--no-warmup` for one local interactive run or set `ZCODER_WARMUP=false`
to disable local startup warm-up by default. One-shot mode does not warm
separately from its real request.

Remote-agent servers do not warm at process launch. A client handshake checks
whether that server's configured model is currently resident in Ollama and
warms it only when needed. The client displays `[ Warming Up ]` while it polls
the server. Every prompt performs another residency check in case local work or
another remote server evicted the model after connection. A prompt submitted
during that race remains queued until preparation succeeds. This allows
separate coding and sysadmin servers to share hardware that can hold only one
model without continuously loading both. Remote readiness is connection-driven,
so `--no-warmup` continues to control only local interactive startup and does
not disable the server's connection and pre-turn checks.

## Prompt profiles

The `coding` profile is the normal project agent. It searches before reading
broadly, works in small verifiable steps, and can accept session-wide shell
approval.

The `sysadmin` profile begins with read-only diagnosis and requires separate
approval for every shell command. It adds least-privilege, rollback, validation,
backup, redaction, and critical-service safeguards. Project `AGENTS.md` guidance
is still appended, but cannot relax these rules.

Set the default or select it explicitly:

```sh
export ZCODER_PROFILE=sysadmin

./zcoder.zsh --profile sysadmin --model qwen3-coder \
  --workspace /path/to/maintenance-workspace
```

See [Safety and permissions](safety.md) for the full distinction.

## Context sizing

Context sizing defaults to `auto`:

- If the model is already loaded, zcoder uses the allocation reported by Ollama's `/api/ps`.
- If it is unloaded, a conservative 65,536-token value is used for initial internal accounting.
- The first unloaded-model request omits `num_ctx`, allowing Ollama to honor the model's Modelfile or server default.
- After the response, zcoder refreshes its accounting from `/api/ps`.

Use `--context-window TOKENS` or `ZCODER_CONTEXT_WINDOW` to request an explicit
allocation from the first turn. zcoder supports explicit allocations of 32,768
tokens or more; 32K and 64K are its intended local operating sizes. Larger
contexts consume more memory. `/context` shows the active allocation, estimate,
compaction threshold, output ceiling, and a component-level estimated context
bill.

## Compaction

zcoder uses continuation checkpoints rather than silently discarding old turns:

1. `prompt_eval_count` calibrates a conservative token estimate. Before the first sample, zcoder estimates three bytes per token plus template headroom.
2. Automatic compaction begins at 85% of the allocated context by default.
3. A non-thinking Ollama request reuses the normal system/tool prefix, instructs the model not to call tools, and creates a schema-validated JSON checkpoint capped at 2,048 tokens or 10% of the active context, whichever is smaller.
4. The initial request and latest correction are pinned verbatim, while additional recent user turns fill a soft token budget.
5. The recent history boundary expands when necessary so a tool result never survives without its owning assistant tool call.
6. Malformed, empty, or schema-invalid checkpoints receive up to two corrective retries by default. Exhausted or low-yield checkpoints are rejected without replacing exact history.
7. If the checkpoint request is too large, zcoder removes the oldest unpinned detailed records until the request fits its safety margin.

The visible transcript is not discarded. `/compact` creates a checkpoint
manually; `/context` reports checkpoint count and current estimates.

After compaction, the automatic threshold rearms above the new checkpoint size.
Repeated checkpoints summarize the previous one plus newer detailed history.
Any summary can gradually lose precision, so a focused new session remains the
best choice when a long thread changes direction.

Relevant settings:

| Setting | Default |
| --- | ---: |
| `ZCODER_CONTEXT_WINDOW` | `auto` |
| `ZCODER_CONTEXT_FALLBACK` | 65536 |
| `ZCODER_COMPACT_PERCENT` | 85 |
| `ZCODER_COMPACT_MAX_TOKENS` | 2048 |
| `ZCODER_COMPACT_KEEP_USER_TOKENS` | 4096 |
| `ZCODER_COMPACT_KEEP_RECENT_TOKENS` | 16384 |
| `ZCODER_COMPACT_MIN_YIELD_TOKENS` | 2048 |
| `ZCODER_COMPACT_RETRY_LIMIT` | 2 |
| `ZCODER_MAX_OUTPUT_TOKENS` | 8192 |

`--compact-at PERCENT` changes the threshold for one process.

## Loop and completion controls

| Setting | Default | Purpose |
| --- | ---: | --- |
| `ZCODER_LOOP_REPEAT_LIMIT` | 3 | Repetition threshold before recovery |
| `ZCODER_LOOP_MAX_CYCLE` | 4 | Longest alternating cycle inspected |
| `ZCODER_INCOMPLETE_RETRY_LIMIT` | 3 | Empty or malformed response retries |
| `ZCODER_TRANSPORT_RETRY_LIMIT` | 1 | Retries after a transient failure before any Ollama response |
| `ZCODER_REQUIRE_FINISH_TOOL` | 0 | Require structural `finish` completion when set to 1 |
| `ZCODER_GOAL_MAX_REJECTIONS` | 3 | Independent verifier rejections before stopping a goal |
| `ZCODER_GOAL_VERIFIER_MAX_STEPS` | 8 | Read-only verifier turns allowed for one candidate |

See [Architecture](architecture.md) for how these controls affect the agent loop.
Response timeouts are not retried: replaying a generation that already consumed
the full timeout would restart the same expensive work. Increase
`ZCODER_HTTP_READ_TIMEOUT` for slower hardware or very large contexts.

`/goal --tokens N OBJECTIVE` applies a cumulative Ollama prompt-plus-output
token limit to that goal. Omitting `--tokens` leaves the goal unlimited except
for the rejection, loop, error, and cancellation guards. `/goal resume` removes
an exhausted token limit; start a new goal with `--tokens` to apply a new one.

## Debug logs

Enable diagnostics without writing through curses:

```zsh
./zcoder.zsh --debug --model qwen3-coder --workspace /path/to/project
tail -f /tmp/zcoder-debug-${UID}.log
```

Use `--debug-log PATH` or `ZCODER_DEBUG_LOG` for another location.
`ZCODER_DEBUG_MAX_CHARS` changes the per-record limit.

The log records session and exit state, Ollama request status, bounded raw
responses, parsed content and tool-call counts, continuation decisions, and
bounded tool-result summaries. It can contain prompts, assistant text, paths,
and tool arguments. Treat it as sensitive.

[Documentation index](README.md) · [Getting started](getting-started.md) · [Project README](../README.md)

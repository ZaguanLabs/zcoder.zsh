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
| `ZCODER_WARMUP` | `true` | Warm the model and stable prompt context when the interactive TUI starts |
| `ZCODER_MAX_TOOL_OUTPUT` | 32768 | Maximum returned tool-output characters |
| `ZCODER_HOME` | `${XDG_CONFIG_HOME:-$HOME/.config}/zcoder` | User configuration and sessions |

Command-line values take precedence where an equivalent flag exists.

## Interactive model warm-up

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

Use `--no-warmup` for one interactive run or set `ZCODER_WARMUP=false` to
disable it by default. One-shot and remote-client modes do not perform local
warm-up.

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
allocation from the first turn. Larger contexts consume more memory. `/context`
shows the active allocation, estimate, and compaction threshold.

## Compaction

zcoder uses continuation checkpoints rather than silently discarding old turns:

1. `prompt_eval_count` calibrates a conservative token estimate. Before the first sample, zcoder estimates three bytes per token plus template headroom.
2. Automatic compaction begins at 85% of the allocated context by default.
3. A tool-free, non-thinking Ollama request creates a concise checkpoint, capped at 2,048 tokens or 10% of the active context, whichever is smaller.
4. The latest complete assistant/tool exchange and a bounded exact-user ledger remain available alongside the checkpoint.
5. If the checkpoint request is too large, zcoder removes the oldest detailed records until the request fits its safety margin.

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

`--compact-at PERCENT` changes the threshold for one process.

## Loop and completion controls

| Setting | Default | Purpose |
| --- | ---: | --- |
| `ZCODER_LOOP_REPEAT_LIMIT` | 3 | Repetition threshold before recovery |
| `ZCODER_LOOP_MAX_CYCLE` | 4 | Longest alternating cycle inspected |
| `ZCODER_INCOMPLETE_RETRY_LIMIT` | 3 | Empty or malformed response retries |
| `ZCODER_REQUIRE_FINISH_TOOL` | 0 | Require structural `finish` completion when set to 1 |

See [Architecture](architecture.md) for how these controls affect the agent loop.

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

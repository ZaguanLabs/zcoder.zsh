# Development

zcoder targets Zsh 5.8 and newer. Keep application logic Zsh-first and preserve
the separation between Ollama, tool dispatch, persistence, remote transport,
and curses.

## Project checks

Run the complete required suite before handing off changes:

```sh
make test
```

`make test` first parses the entry points, libraries, and tests with `zsh -n`,
then runs the shell-level suite. The suite covers:

- native JSON parsing and encoding
- both supported MCP protocol generations
- paginated MCP discovery and nested tool calls
- reasoning and tool history
- serialized per-call dispatch and transport recovery
- context accounting and compaction
- path and symlink confinement
- file reads, writes, search, and patch fallback
- loop detection and completion recovery
- sessions, Skills, and project instructions
- Ollama, delegate, and remote cancellation
- command approval, denial, and safety guards
- authenticated remote events and approvals
- input handling and curses rendering

Run syntax checks alone with:

```sh
make check
```

## Real-model evaluation

Real inference is opt-in and not part of `make test`. The evaluation target
creates isolated temporary workspaces, denies shell commands, and reports
tab-separated results for repeated reads, dependent search, edit-and-verify,
failure recovery, and conversational scenarios.

```sh
ZCODER_EVAL_MODELS='ornith-1.5:9b,laguna-xs-2.1' \
ZCODER_EVAL_REPEATS=3 \
make model-eval
```

Set `ZCODER_EVAL_BASELINE_PROMPT_FILE` to a complete earlier system prompt to
compare `current` and `baseline` variants. The `{{WORKSPACE}}` placeholder is
replaced with each temporary fixture path.

Model availability, quantization, sampling defaults, and Ollama configuration
remain the operator's responsibility.

## Implementation expectations

- Prefer native Zsh modules and parameter expansion for application logic.
- Use external tools when they are the capability: `rg`, `git apply`, `patch`, and approved commands.
- Keep model-exposed file operations inside `ZCODER_WORKSPACE`, including symlink resolution.
- Never bypass the `run_command` approval policy.
- Keep tool dispatch independently testable from curses and Ollama.
- Update the patch release before a Git push; change the minor release only when directed by a maintainer.

[Documentation index](README.md) · [Architecture](architecture.md) · [Project README](../README.md)

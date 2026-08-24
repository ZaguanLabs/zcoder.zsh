# Getting started

zcoder.zsh is a Zsh-first coding agent for Ollama. It operates inside a selected
workspace and can inspect files, make changes, apply patches, and request shell
commands as it works toward an outcome.

## Requirements

For normal interactive use:

- Zsh 5.8 or newer, with its standard loadable modules
- a running Ollama server and a model with tool-calling support
- `ripgrep` (`rg`) for file listing and search
- `git` or `patch` for applying patches; install both for the broadest format support
- `stty` for adaptive terminal resize detection

GNU `timeout` is optional. Without it, approved shell commands still work, but
their configured time limits are not enforced. `make` and `mktemp` are needed
only for development and the test suite.

Claude Code, Codex, Google Antigravity, and OpenCode are optional read-only
consultants. The Skills CLI is also optional: zcoder reads installed Agent Skill
directories directly. Stdio MCP support adds no runtime dependency.

## Install and run

Start Ollama, pull a suitable model, clone the project, and select a workspace:

```sh
ollama pull qwen3-coder
git clone https://github.com/ZaguanLabs/zcoder.zsh.git
cd zcoder.zsh
./zcoder.zsh --model qwen3-coder --workspace /path/to/project
```

The model name is passed to Ollama as written. Your model must support
structured tool calls for agent work.

## One-shot mode

Use `--prompt` when you want a single non-interactive request:

```sh
./zcoder.zsh --model qwen3-coder --workspace . \
  --prompt "Inspect this project and explain how it is organized"
```

One-shot mode still asks on `/dev/tty` before running shell commands. Pass
`--yes` to allow them for that process or `--deny-commands` to refuse them.

## Essential options

```text
-m, --model NAME       Ollama model
-h, --host HOST        Ollama host
-w, --workspace PATH   Directory the agent may access
    --profile NAME     coding or sysadmin
-p, --prompt TEXT      Run one prompt without the full-screen UI
    --context-window N Context tokens, or auto
    --compact-at PCT   Automatic compaction threshold
    --yes              Allow shell commands in the coding profile
    --deny-commands    Deny shell commands without prompting
    --no-think         Ask Ollama not to return model reasoning
    --no-warmup        Disable interactive model warm-up
    --debug            Enable the default debug log
    --debug-log PATH   Write diagnostics to a selected path
```

Run `./zcoder.zsh --help` for the complete current list, including remote-agent
options.

## Choose a profile

The default `coding` profile is designed for project work inside a bounded
workspace. The `sysadmin` profile is intended for careful host maintenance:

```sh
./zcoder.zsh --profile sysadmin --model qwen3-coder \
  --workspace /path/to/maintenance-workspace
```

The sysadmin profile requires separate approval for every shell command and
disables `--yes`. Read [Safety and permissions](safety.md) before using it.

## Next steps

- Learn the [interface and session controls](interface.md).
- Add repository-specific behavior with [project guidance and Agent Skills](project-guidance.md).
- Work on another machine with the [remote-agent server](remote.md).
- Review [configuration and context management](configuration.md).

[Documentation index](README.md) · [Project README](../README.md)

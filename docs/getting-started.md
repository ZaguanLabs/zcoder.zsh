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
- `stty` for adaptive terminal resize detection with the stock curses module

When the loaded `zdraw` module supports `zdraw geometry`, resize polling
uses its native terminal query. Otherwise it uses `stty`. Modules exposing the
read-only `zdraw_features` array select the backend on UI entry, without a
terminal query. Advertised geometry support survives transient query failures,
including the first one: the layout stays intact until a successful poll.
Older modules are probed on the first resize poll; a failed initial probe keeps
the fallback for that session. No configuration is required.

GNU `timeout` is optional. Without it, approved shell commands still work, but
their configured time limits are not enforced. `make` and `mktemp` are needed
only for development and the test suite.

Claude Code, Codex, Google Antigravity, and OpenCode are optional external
harnesses. Their plain slash commands provide read-only consultations; explicit
bang commands can run them as workspace-editing workers. The Skills CLI is also
optional: zcoder reads installed Agent Skill directories directly. Stdio MCP
support adds no runtime dependency.

Use `/help` in the TUI to see which external harness binaries are available on
the zcoder host. When connected remotely, this list comes from the server host,
not the workstation.

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

## Enhanced curses module

The Git submodule at `vendor/zdraw` pins the experimental
[ZaguanLabs module](https://github.com/ZaguanLabs/zdraw). Its native geometry
query removes the `stty size` subprocess from each due resize poll (up to four
per second). Enable it locally with:

```sh
git submodule update --init --recursive
ZSH_BUILD_ROOT=/path/to/matching/configured/zsh make curses
make test
./zcoder.zsh --workspace /path/to/project
```

The current dependency builds against its recorded Zsh 5.9.2 source baseline;
it needs a configured, built source tree matching the installed shell, Make,
a C compiler, and that tree's development dependencies. See
[development](development.md#building-the-curses-dependency) for details.
Zsh 5.8 continues to use the stock module.

Once built, ordinary launches automatically select the local module. `/terminal`
shows the selected module and resize-query backend. Set `ZCODER_CURSES=stock`
to bypass the bundled module for a run. Without a matching local build, zcoder
uses the system module. Headless server and ACP modes do not load curses.

When the module advertises `structured_events` and `norefresh_events`, input
reads leave unfinished drawing hidden until the next explicit frame refresh.
Paste handling and terminal-reply filtering stay active. `/terminal` shows
the selected input presentation mode; older modules use legacy input.

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

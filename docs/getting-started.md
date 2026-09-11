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
their configured time limits are not enforced. GNU Make and a C toolchain are needed for the optional native setup below.
`mktemp` is also needed for the test suite.

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
make
./zcoder.zsh --model qwen3-coder --workspace /path/to/project
```

The model name is passed to Ollama as written. Your model must support
structured tool calls for agent work.

## Enhanced curses module

Plain `make` (or `make setup`) builds the enhanced interface, including zdraw
and zmdown. It initializes both pinned submodules, downloads Zsh 5.9.2 from
zsh.org, verifies its pinned SHA-256 checksum, and builds a private shell with
both modules. You do not need to find or configure your system shell's sources.

Build requirements:

- Zsh 5.8+, Git, GNU Make (`gmake` on systems where `make` is not GNU Make)
- a C compiler, standard Unix build tools, Autoconf, Autoheader, M4 and Patch
- wide-character ncurses development headers/libraries and a terminfo database
- Curl, Tar and Xz; either `sha256sum` or `shasum` for archive verification

These are build-time tools. The Makefile reports missing commands; it does not
install operating-system packages or use sudo. For nonstandard ncurses paths,
supply `CPPFLAGS` and `LDFLAGS`. Use a checkout path without whitespace or shell
metacharacters because Zsh's upstream makefiles do not support those paths.
Linux is tested; BSD/macOS native builds still need validation.

```sh
make
./zcoder.zsh --workspace /path/to/project
```

Build files and logs stay under `.build/native/`. The private shell is used
only to run this application; your login shell and system Zsh are unchanged.
The launcher selects it automatically when its host and checkout path match.
`ZCODER_RUNTIME=system ./zcoder.zsh` uses the installed shell instead. Missing,
copied or relocated private runtimes fall back to the installed shell; run
`make` on the destination to build a matched set there.

Repeat `make` after pulling updates. Successful matching builds are reused;
failed rebuilds leave the previous runtime available. Downloads are cached and
verified on rebuild. .build/native/lock prevents concurrent builds and is released automatically
when the build exits, including after interruption. Inspect
`.build/native/build.log` when configuration or compilation fails.

`make native` builds only the runtime and modules. `make curses` and
`make markdown` also prepare the matched set unless you explicitly supply
`ZSH_BUILD_ROOT` for an advanced system-shell build. `make compile` still only
compiles application libraries and never downloads or builds C code, so headless
farm deployments retain their lightweight workflow. You can skip native setup
entirely and run the script with the existing Zsh renderer.

`/terminal` reports `private` when the private zdraw module is selected and
`zmdown` when native Markdown is active. Use a UTF-8 locale for that rendering
path. `ZCODER_CURSES=stock` selects stock curses; `ZCODER_MARKDOWN=zsh` selects
the Zsh Markdown renderer. Headless server and ACP modes do not load curses.

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

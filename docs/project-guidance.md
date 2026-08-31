# Project guidance and Agent Skills

zcoder can combine persistent project instructions with task-specific Skills.
Both are loaded with bounded context and remain subordinate to the workspace,
approval, and safety rules.

## `AGENTS.md` precedence

At startup, zcoder builds an instruction chain from broad guidance to the most
specific workspace guidance:

1. Global guidance from `$ZCODER_HOME/AGENTS.override.md`, otherwise `$ZCODER_HOME/AGENTS.md`.
2. Project guidance from the nearest Git root down to the selected workspace.
3. Without a Git root, only the workspace directory is checked.
4. In each directory, the first non-empty match wins: `AGENTS.override.md`, `AGENTS.md`, then configured fallback names.
5. Files are merged from broadest to most specific, so nested guidance takes precedence.

`ZCODER_HOME` defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/zcoder`.

The combined instruction-content limit defaults to 32 KiB. Configure fallback
filenames and the limit with:

```sh
export ZCODER_PROJECT_DOC_FALLBACKS='TEAM_GUIDE.md:.agents.md'
export ZCODER_PROJECT_DOC_MAX_BYTES=65536
```

Instructions are loaded when zcoder starts. Audit the resolved chain without
contacting Ollama:

```sh
./zcoder.zsh --workspace /path/to/project --print-instructions
```

Inside the TUI, `/instructions` lists the active sources. The base prompt also
tells the model to check for closer instruction files before changing files in
nested directories.

## Agent Skills

zcoder implements the open [Agent Skills](https://agentskills.io) format with
progressive disclosure. At startup it parses only each valid `SKILL.md` name and
description. This bounded routing catalog stays visible in the recurring model
prompt so the model can match an unqualified request against installed
capabilities. When a request names a Skill or clearly matches its description,
the model must call `activate_skill` before doing that work. Full instructions
enter context only after activation.

If the routing catalog exceeds its configured count or byte limit, the prompt
marks it as truncated and exposes `discover_skills` as a fallback for a focused
capability query. The discovery tool is omitted when the complete bounded
catalog is already visible.

Referenced scripts, documentation, and assets are read individually with
`read_skill_resource`; they are not loaded eagerly.

The standard discovery locations are:

- project: `<project-root>/.agents/skills/<name>/SKILL.md`
- user: `~/.agents/skills/<name>/SKILL.md`
- user config: `${XDG_CONFIG_HOME:-$HOME/.config}/agents/skills/<name>/SKILL.md`

Project Skills override same-named user Skills.

## Activate and inspect Skills

Audit discovery without contacting Ollama:

```sh
./zcoder.zsh --workspace /path/to/project --print-skills
```

Inside the TUI:

- `/skills` lists discovered and active Skills.
- `/skills reload` rescans the standard locations.
- `/skill NAME` activates one Skill.
- Prefixing a request with `$skill-name` activates it before the first model turn.

Otherwise, the model selects directly from the visible routing descriptions and
activates a matching Skill when relevant. Active Skill instructions remain in
the system prompt, survive conversation compaction, and are cleared by `/new`.

## Limits

| Setting | Default | Purpose |
| --- | ---: | --- |
| `ZCODER_MAX_SKILLS` | 128 | Maximum Skills available to model routing and fallback discovery |
| `ZCODER_SKILL_CATALOG_MAX_BYTES` | 32 KiB | Model-visible routing metadata limit |
| `ZCODER_SKILL_MAX_BYTES` | 32 KiB | Maximum activated body size |
| `ZCODER_ACTIVE_SKILLS_MAX_BYTES` | 64 KiB | Combined active body limit |
| `ZCODER_MAX_ACTIVE_SKILLS` | 8 | Simultaneously active Skills |

The recurring activation schema does not repeat catalog names because they are
already present in the routing prompt. Model-initiated activation is restricted
to the bounded discoverable set; explicit user activation can still select any
valid discovered Skill.

## Trust model

Skill files and bundled resources may be untrusted. Their instructions cannot
override the base profile, project guidance, workspace boundary, sysadmin
restrictions, or command approval. The experimental `allowed-tools` frontmatter
field is not treated as permission. Running a bundled script still requires an
ordinary approved `run_command`.

[Documentation index](README.md) · [Safety and permissions](safety.md) · [Project README](../README.md)

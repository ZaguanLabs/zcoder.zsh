# zcoder.zsh documentation

This directory contains the detailed guides and reference material for
zcoder.zsh. If you are new to the project, begin with
[Getting started](getting-started.md).

## Use zcoder

| Guide | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Requirements, installation, first run, one-shot use, and essential options |
| [Interface and sessions](interface.md) | TUI layout, keyboard controls, slash commands, saved jobs, consultants, and external workers |
| [Steering and queued follow-ups](queued-input.md) | Active-turn input, recovery, HTTP endpoints, and ACP extension |
| [Remote-agent server](remote.md) | Running zcoder beside a remote model and workspace |
| [Safety and permissions](safety.md) | Workspace boundaries, command approval, trust boundaries, and sysadmin safeguards |

## Extend and configure it

| Guide | What it covers |
| --- | --- |
| [Project guidance and Agent Skills](project-guidance.md) | `AGENTS.md` precedence, Skill discovery, activation, and limits |
| [MCP servers](mcp.md) | Stdio MCP configuration, commands, protocol support, and trust model |
| [Configuration and context management](configuration.md) | Profiles, context sizing, compaction, debugging, and environment controls |

## Understand and contribute

| Guide | What it covers |
| --- | --- |
| [Architecture](architecture.md) | Source layout, agent loop, HTTP behavior, batching, completion, and remote transport |
| [Inter-agent communication](inter-agent-communication.md) | Same-host Unix-socket discovery, task delivery, queuing, safety, and implementation details |
| [Remote access system API specification](remote-access-system-specification.md) | Protocol-1 wire API, state machines, reimplementation requirements, security, and conformance tests |
| [HTTPS and WSS libcurl bridge](libcurl-transport-bridge.md) | Proposed hosted-model transport boundary, helper process, loadable module, security, and test plan |
| [External agent runtimes](external-agent-runtimes.md) | Codex, Claude, and Antigravity protocols, authentication, Zsh boundaries, and implementation direction |
| [Development](development.md) | Test suite, repeatable benchmarks, model evaluation, compatibility expectations, and contribution checks |

## Releases

- [v0.12.3 — Bound context accounting memory](releases/v0.12.3.md)
- [v0.12.2 — Native Zsh performance and reliability](releases/v0.12.2.md)

- [v0.12.1 — Steering, queued follow-ups, and a clearer conversation](releases/v0.12.1.md)
- [v0.12.0 — Steering and queued follow-ups](releases/v0.12.0.md)
- [v0.11.2 — Antigravity model refresh](releases/v0.11.2.md)
- [v0.11.1 — Post-compaction history fix](releases/v0.11.1.md)
- [v0.11.0 — ACP integration and model-neutral compaction](releases/v0.11.0.md)
- [v0.10.0 — Verified goals and skill-aware routing](releases/v0.10.0.md)
- [v0.9.0 — Local agent handoffs and sharper local models](releases/v0.9.0.md)
- [v0.8.0 — External workers and runtime hardening](releases/v0.8.0.md)
- [v0.7.0 — Model readiness and remote sessions](releases/v0.7.0.md)
- [v0.6.0 — Performance and hardening](releases/v0.6.0.md)
- [v0.5.0 — Remote-agent architecture](releases/v0.5.0.md)

[Back to the project README](../README.md)

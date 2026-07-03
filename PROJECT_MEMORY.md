# PROJECT_MEMORY.md

This file is the shared project memory for AI agents.

## File Roles

- `AGENTS.md`: Codex entrypoint and Codex-specific operating rules.
- `CLAUDE.md`: Claude Code entrypoint and Claude-specific operating rules.
- `PROJECT_MEMORY.md`: shared project rules, durable memory, decisions, commands, identifiers, and follow-up context.

Keep README files for human-facing project documentation. Do not store AI memory in `README.md` unless the user explicitly asks.

## Project Rules

### Instruction File Language

Use English for prose in `AGENTS.md`, `CLAUDE.md`, and `PROJECT_MEMORY.md`. Preserve exact non-English names, paths, UI labels, business terms, and user-facing examples when they are identifiers or source facts.

### Conflict Checks

Before changing `AGENTS.md`, `CLAUDE.md`, or `PROJECT_MEMORY.md`, check the proposed change against all three files and warn the user if it conflicts with existing agent operating rules or project memory.

Add stable project rules here, such as required tools, safety constraints, naming conventions, environment rules, and verification gates.

## Durable Memory

Add durable facts, user preferences, architectural decisions, important commands, known pitfalls, and next actions here.
Do not add transient chat logs, scratch notes, or speculation.

# Copilot instructions

This file mirrors `CLAUDE.md` for GitHub Copilot. The full guardrail rationale is in `CLAUDE.md` at the repository root - read that first.

## Hard rules

This repository is **public**. Identifiable information must never appear in code, comments, examples, fixtures, or commit messages.

Forbidden in any committed file:

- Hostnames or URLs of real internal/private systems.
- IP addresses outside `0.0.0.0` or RFC5737 ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
- API keys, tokens, passwords, connection strings (any form, even rotated/expired).
- Personal names (employees, collaborators, customers).
- Email addresses other than `someone@example.com` / `noreply@example.com`.
- Physical addresses.
- Customer / vendor / product names that identify a real third party.
- Internal codenames, project names, ticket numbers, Slack channels.
- Real Azure subscription IDs / tenant IDs / resource group names tied to an org.
- GitHub usernames or org names other than `hoobio`.

Allowed:
- The `hoobio` GitHub user/org name.
- Public well-known action references (`actions/checkout@v5`, etc.).
- Workflow context expressions: `${{ github.* }}`, `${{ inputs.* }}`, `${{ secrets.* }}`.
- ADO context: `$(varName)`, `$(System.*)`.
- Generic placeholders (`example.com`, RFC5737 IPs, `xxxx-xxxx`, all-zero UUIDs).

## Authoring rules

- Hostnames, ports, paths, account IDs, and secrets MUST come from parameters / inputs / variables - never hardcoded.
- PowerShell: use `[CmdletBinding()]` with typed, validated parameters. Never default to internal values.
- YAML templates: declare every input with a `description`. No implicit env vars.
- Examples: use `example.com`, RFC5737 IPs, all-zero UUIDs.
- Tests / fixtures: synthetic data only.
- Commit messages: describe the change, not the author. Conventional Commits, no emoji.

## Cross-platform parity (GitHub <-> Azure DevOps)

Every reusable building block ships in both flavours, both wrapping the same PowerShell script in `scripts/`. When you add or change anything under `pipeline/`, update both sides in the same PR.

| Concept | GitHub Actions | Azure DevOps |
|---|---|---|
| Step | `pipeline/github/step/<name>/action.yml` | `pipeline/ado/templates/step/<group>/<name>.yaml` |
| Job | `pipeline/github/job/<name>/action.yml` | `pipeline/ado/templates/job/<name>.yaml` |
| Logic | `scripts/<group>/Verb-Noun.ps1` (single source of truth) | _(same script, called from both)_ |

Workflow when adding a new feature:

1. Write the PowerShell script first under `scripts/`. Both wrappers refer to its parameters.
2. Add the GitHub composite action; route values via `env:`.
3. Add the matching ADO template; route values via `env:` (ADO refuses to substitute secret variables into script bodies, so `env:` mapping is mandatory).
4. Keep input names equivalent (kebab-case `server-url` <-> camelCase `serverUrl` is fine, meaning must match).
5. Mirror README sections and orchestrator parameters.

A PR that adds something to one platform without the other is incomplete.

## Tech preferences

- PowerShell for scripts (preferred over Bash / Python).
- YAML 2-space indentation.
- Approved PowerShell verbs only (`Get-Verb`).
- Pin all action references to a tag (e.g. `actions/checkout@v5`), never `@main`.

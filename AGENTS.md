# pipeline-tools

Reusable CI/CD pipeline templates and PowerShell scripts. Targets GitHub Actions and Azure DevOps Pipelines.

## CRITICAL: this repo is public, never commit identifiable information

> **Treat every commit as if it is broadcast to the public internet, because it is.** Anything pushed here is permanently visible in the git history even after deletion. Before staging any change, ask: "would this be a problem if a stranger read it?"

The following MUST NEVER appear in any file (code, comments, examples, sample configs, test fixtures, README, commit messages):

| Category | Forbidden | Replacement |
|---|---|---|
| Hostnames | Internal hosts (`dt.internal.example.com`, `argocd.corp.local`, `srv01.foo.io`) | Workflow input / `secrets.X` / `dt.example.com` / `<your-host>` |
| IP addresses | RFC1918 internal IPs, real public IPs | `0.0.0.0`, RFC5737 docs ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) |
| API keys / tokens / passwords | Any real secret value, even rotated/expired | `${{ secrets.X }}` (GitHub) / `$(varName)` (ADO) / fake placeholders like `xxxx-xxxx` |
| Personal names | Real employee, collaborator, or customer names | Generic role descriptions ("the operator", "a maintainer") |
| Email addresses | Real personal or corporate emails | `someone@example.com`, `noreply@example.com` |
| Physical addresses | Office, datacenter, or customer addresses | Omit or generalise |
| Customer / vendor names | Identifiable company or product names | Generic placeholders, never name third parties |
| Internal codenames | Project / team / Slack-channel codenames | Generic descriptors |
| Cloud identifiers tied to a real org | Real subscription IDs, tenant IDs, resource group names | Use input parameters or sample UUIDs (`00000000-0000-0000-0000-000000000000`) |
| GitHub usernames / orgs (other than hoobio) | Other people's handles, internal org names | Don't reference; if needed for `uses:`, link to the action's documented public repo |

Allowed:
- The `hoobio` GitHub user/org name (this repo lives there).
- Action references with public well-known publishers (`actions/checkout@v5`, etc.).
- Workflow context expressions: `${{ github.repository }}`, `${{ inputs.X }}`, `${{ secrets.Y }}`.
- ADO context: `$(varName)`, `$(System.X)`.

## Authoring rules

- All hostnames, ports, paths, account IDs, and secrets MUST come from script parameters, action inputs, or pipeline variables. Never hardcode them.
- All PowerShell scripts MUST use `[CmdletBinding()]` advanced parameters (typed, validated). They MUST NOT silently default to internal values.
- All YAML templates MUST declare every required input explicitly with a `description`. No "secret" implicit env vars.
- Examples in READMEs MUST use `example.com`, RFC5737 IPs, and obviously synthetic UUIDs/keys.
- Tests / fixtures MUST use synthetic data only.
- Commit messages MUST NOT name people. Describe the change, not the author.
- Commit *author email* MUST use the GitHub noreply form (`<id>+<user>@users.noreply.github.com`). Real personal or corporate email addresses leak through `git log` even if the working tree is clean. Configure once per clone:

  ```bash
  git config user.email "<your-id>+<your-user>@users.noreply.github.com"
  ```

## Pre-commit checklist

Before every commit run through this list. If any answer is "yes", fix before pushing.

- [ ] Did I add a hostname or URL that points to a real internal/private system?
- [ ] Did I add an IP that isn't `0.0.0.0` or in the RFC5737 documentation ranges?
- [ ] Did I paste a token, key, or password (even one I think is safe)?
- [ ] Did I name a real person, company, or customer?
- [ ] Did I leave a TODO/FIXME with internal context (ticket numbers, codenames, employee handles)?
- [ ] Did I copy a fragment from an internal repo without sanitising it?

`git diff --check` and a manual review of the diff is required before push.

## Repository structure

```
pipeline/
  ado/templates/{step,stage,job}/        # Azure DevOps YAML templates
  github/{step,job}/                     # GitHub Actions composite actions
                                         # (one action.yml per directory)
scripts/
  dependency-track/                      # PowerShell helpers for DT REST API
  sbom/                                  # PowerShell helpers for SBOM generation
.github/
  dependabot.yml                         # Dependency updates
  workflows/                             # Repo's own CI (lint, validate)
```

GitHub Actions composite actions live as directories containing an `action.yml`. Consumers reference them by path:

```yaml
- uses: hoobio/pipeline-tools/pipeline/github/step/<name>@<tag-or-sha>
```

Reusable GitHub *workflows* (the `workflow_call` kind) cannot live outside `.github/workflows/` due to a GitHub platform constraint, so the `pipeline/github/job/` directory uses composite actions instead. They behave like a "job" by orchestrating several steps under one action.

## Cross-platform parity (GitHub <-> Azure DevOps)

Every reusable building block ships in both flavours, both wrapping the same PowerShell script in `scripts/`. When you add or change anything under `pipeline/`, update both sides in the same PR:

| Concept | GitHub Actions location | Azure DevOps location |
|---|---|---|
| Step (single concern) | `pipeline/github/step/<name>/action.yml` | `pipeline/ado/templates/step/<group>/<name>.yaml` |
| Job (orchestrating multiple steps) | `pipeline/github/job/<name>/action.yml` | `pipeline/ado/templates/job/<name>.yaml` |
| Underlying logic | `scripts/<group>/Verb-Noun.ps1` (single source of truth) | _(same script, called from both)_ |

Concretely, when you add a new feature:

1. **Write the PowerShell script first** under `scripts/`. Pin its parameter names; both wrappers refer to them.
2. **Add the GitHub composite action** under `pipeline/github/`. Use `inputs:` with descriptions; route values to the script via `env:`.
3. **Add the matching ADO template** under `pipeline/ado/templates/`. Use `parameters:` with `displayName`s; route values to the script via `env:` (ADO refuses to substitute secret variables into a script body, so `env:` mapping is mandatory).
4. **Keep input names equivalent across the two**: if the GitHub action takes `server-url`, the ADO parameter is `serverUrl` (kebab-case <-> camelCase is fine, but the meaning must match exactly).
5. **Mirror documentation**: README's "GitHub Actions" section and "Azure DevOps Pipelines" section should show equivalent examples.
6. **Mirror orchestrator parameters**: if the GitHub job action gets a new input (e.g. `mark-latest`), the ADO job template gets the same parameter (`markLatest`).

A PR that adds something to one platform without the other is incomplete. Reviewers should reject single-platform changes for features that have a cross-platform analog.

## Tech preferences for this repo

- PowerShell for all scripts.
- 2-space YAML indentation.
- Conventional Commits (no AB# suffix; this is not a Nintex repo).
- No emoji / no gitmoji in commit messages or PR titles.

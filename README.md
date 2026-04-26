# pipeline-tools

Reusable CI/CD pipeline templates and PowerShell scripts. Targets GitHub Actions and Azure DevOps Pipelines, sharing PowerShell logic between the two.

> **This repository is public.** Read [`CLAUDE.md`](CLAUDE.md) before contributing - never commit hostnames, IPs, API keys, personal names, or other identifiable information.

## Layout

```
pipeline/
  ado/templates/{step,stage,job}/   # Azure DevOps templates (placeholder for now)
  github/
    step/                           # Composite actions, one per logical step
      cyclonedx-sbom-dotnet/        # Generate a CycloneDX BOM for a .NET project
      dt-init-parent/               # Ensure DT parent project exists (bootstrap-via-BOM)
      dt-upload-bom/                # Upload a BOM to DT (returns masked upload-token)
      dt-mark-latest/               # Mark project as isLatest = true
      dt-prune-stale-children/      # Delete old children, keep N most recent
      dt-wait-bom-processing/       # Poll until DT finishes processing the upload
      upload-to-github-release/     # Attach a file to a GitHub Release
    job/
      upload-sbom-to-dependency-track/   # Orchestrating composite action
scripts/
  sbom/                             # SBOM-generation PowerShell helpers
  dependency-track/                 # Dependency-Track REST helpers
```

## Why composite actions and not reusable workflows

GitHub Actions only allows reusable workflows under `.github/workflows/`. To keep all reusable building blocks in one organised tree under `pipeline/github/`, we use composite actions. They're consumed exactly the same way:

```yaml
- uses: hoobio/pipeline-tools/pipeline/github/job/upload-sbom-to-dependency-track@<tag-or-sha>
  with:
    ...
```

Pin to a release tag (`@v0.1.0`) or commit SHA. Avoid `@main`.

## GitHub Actions: SBOM upload to Dependency-Track

The job action `upload-sbom-to-dependency-track` consumes a pre-generated CycloneDX BOM and runs the full DT-side pipeline (artifact upload, parent bootstrap, child upload with parent linkage, optional `isLatest`, optional pruning of stale children).

Generation is intentionally separate so each language can use its native tool. Pair this action with whichever generator fits your project:

| Language / Source | Generator step |
|---|---|
| .NET solution / project | `pipeline/github/step/cyclonedx-sbom-dotnet` |
| Node, Python, container, ...     | Bring your own; output a CycloneDX BOM file. |

### .NET example

```yaml
jobs:
  sbom:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-dotnet@v5
        with:
          dotnet-version: '10.0.x'

      - uses: hoobio/pipeline-tools/pipeline/github/step/cyclonedx-sbom-dotnet@<sha>
        with:
          solution-path: src/MySolution.slnx
          output-path: sbom.cdx.json

      - uses: hoobio/pipeline-tools/pipeline/github/job/upload-sbom-to-dependency-track@<sha>
        with:
          bom-path:         sbom.cdx.json
          server-url:       ${{ secrets.DT_SERVER_URL }}    # e.g. https://dt.example.com
          api-key:          ${{ secrets.DT_API_KEY }}
          project-name:     ${{ github.event.repository.name }}
          project-version:  ${{ github.sha }}
          parent-name:      ${{ github.event.repository.name }}
          parent-version:   main
          project-tags:     branch=${{ github.ref_name }},commit=${{ github.sha }}
          mark-latest:      'false'
          prune-stale-children: 'true'
          keep:             '10'
```

### BYO generation example (Node, Python, container, etc.)

```yaml
- name: Generate BOM
  run: |
    # whatever produces a CycloneDX BOM at ./sbom.cdx.json,
    # e.g. cyclonedx-bom, syft, @cyclonedx/cyclonedx-npm, etc.
    ...

- uses: hoobio/pipeline-tools/pipeline/github/job/upload-sbom-to-dependency-track@<sha>
  with:
    bom-path:        sbom.cdx.json
    server-url:      ${{ secrets.DT_SERVER_URL }}
    api-key:         ${{ secrets.DT_API_KEY }}
    project-name:    ${{ github.event.repository.name }}
    project-version: ${{ github.sha }}
```

If you want fine-grained control over the DT-side steps, compose your own job from the step actions under `pipeline/github/step/`. Each step is documented in its `action.yml`.

## PowerShell scripts

The composite actions are thin shells over PowerShell scripts in `scripts/`. The scripts are independently usable from Azure DevOps templates, local workstations, or any other PowerShell 7+ context.

Public scripts:

| Script | Purpose |
|---|---|
| [`scripts/sbom/New-CycloneDxSbom.ps1`](scripts/sbom/New-CycloneDxSbom.ps1) | Generate a CycloneDX BOM for a .NET solution. |
| [`scripts/dependency-track/Initialize-DTParentProject.ps1`](scripts/dependency-track/Initialize-DTParentProject.ps1) | Ensure a DT parent project exists; bootstrap via BOM upload if missing. |
| [`scripts/dependency-track/Send-DTBom.ps1`](scripts/dependency-track/Send-DTBom.ps1) | Upload a CycloneDX BOM to DT. Drop-in replacement for the `DependencyTrack/gh-upload-sbom` action. |
| [`scripts/dependency-track/Set-DTProjectLatest.ps1`](scripts/dependency-track/Set-DTProjectLatest.ps1) | Mark a project version as `isLatest = true`. |
| [`scripts/dependency-track/Remove-DTStaleChildren.ps1`](scripts/dependency-track/Remove-DTStaleChildren.ps1) | Prune old child projects under a parent. |
| [`scripts/dependency-track/Wait-DTBomProcessing.ps1`](scripts/dependency-track/Wait-DTBomProcessing.ps1) | Poll DT until a BOM upload finishes processing, or fail on timeout. |

Private (internal) helper:

| Script | Purpose |
|---|---|
| [`scripts/dependency-track/private/Invoke-DTRestMethod.ps1`](scripts/dependency-track/private/Invoke-DTRestMethod.ps1) | Internal HTTP helper used by the public DT scripts. Not for direct consumption. |

All public scripts use `[CmdletBinding()]` with typed, validated parameters. Run `Get-Help <script> -Full` for detailed usage.

## Permissions

The DT scripts assume the API key has at minimum `PROJECT_CREATION_UPLOAD`. The pruning script additionally needs project-delete permission (typically `PORTFOLIO_MANAGEMENT`). The bootstrap path deliberately uses `POST /api/v1/bom` instead of `PUT /api/v1/project` so that workflows with only the lower-privilege key still work.

## Versioning and releases

This repo uses [release-please](https://github.com/googleapis/release-please) to drive Conventional-Commits-based releases. Pushing to `main` opens (or updates) a release PR with the next version and a `CHANGELOG.md` entry. Merging the release PR creates the tag and a GitHub Release.

- Pin consumers to a release tag (`@v0.1.0`, `@v0.2.0`, ...) or a commit SHA. Avoid `@main`.
- Tags matching `v*` are protected against deletion and force-update; release assets are immutable once published.
- Breaking changes bump the major version. Call out the migration in the release notes.

PR titles are validated against Conventional Commits by `.github/workflows/pr-title-check.yaml`. Allowed types: `feat`, `fix`, `perf`, `revert`, `docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore`. Only `feat` / `fix` / `perf` / `revert` produce changelog entries that trigger a version bump.

## Contributing

1. Read [`CLAUDE.md`](CLAUDE.md) carefully.
2. PowerShell only for new scripts; no Bash, no Python.
3. Conventional Commits, no emoji, no AB# suffix.
4. Manually review the diff before push - especially for hardcoded URLs, IPs, names.

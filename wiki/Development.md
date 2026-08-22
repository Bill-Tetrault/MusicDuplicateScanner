# Development

This page covers local setup, linting, testing, and the CI pipeline.

## Prerequisites

- PowerShell 7+ (recommended; PS 5.1 works but Pester 5 and PSScriptAnalyzer run best on PS 7)
- Git
- (Optional) TagLibSharp for integration-level testing against real MP3 files

## One-time setup

```powershell
# Install Pester 5 and PSScriptAnalyzer from the PowerShell Gallery
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
```

## Lint

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The `PSScriptAnalyzerSettings.psd1` file at the repo root configures rule severity. Rules are tuned to avoid false positives from WPF `Add-Type` patterns and intentional dynamic invocations.

## Test

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

The test suite is in `tests/MusicDuplicateScanner.Core.Tests.ps1` and covers:

- `ConvertTo-NormalizedTrackName` — normalization of track numbers, copy-counter suffixes (`(1)`, `- Copy`, etc.), edition markers, and year-preservation edge cases
- `Get-JaccardSimilarity` — empty sets, identical sets, partial overlap, single-element sets
- `Get-ConfidenceScore` — weight distribution for filename/tag/hash components
- `Select-PreferredFile` — bitrate preference, metadata completeness, recency tiebreak, root-vs-subfolder logic (v2.1.0)
- `Move-QuarantineBatchCore` — progress reporting format, path mapping, error handling
- Regression tests for the Int32 overflow bug and the single-group array-concatenation crash fixed in v2.0.0
- Regression tests for `(1)`-suffix detection and year-preservation fixed in v2.0.1

## Folder conventions

| Path | Contents |
|---|---|
| `src/` | Runnable source (Core module + GUI script) |
| `tests/` | Pester tests for Core only |
| `lib/` | Third-party DLLs (TagLibSharp — not committed, see `lib/README.md`) |
| `docs/` | Additional reference documentation |
| `wiki/` | Source for the GitHub wiki pages |
| `.github/workflows/` | GitHub Actions CI definition |

## CI pipeline

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs on every push and pull request to `main`:

1. **PSScriptAnalyzer lint** — runs on `ubuntu-latest` (PS 7); catches style and correctness issues.
2. **Pester unit tests** — runs on `ubuntu-latest` (PS 7); Core module only, no WPF required.
3. **Windows syntax smoke test** — runs on `windows-latest`; loads the GUI script with `-NonInteractive` to verify PS and WPF assembly availability without actually opening the window.

## Adding a new feature

1. Add logic to `src/MusicDuplicateScanner.Core.psm1` and export the function.
2. Write Pester tests in `tests/MusicDuplicateScanner.Core.Tests.ps1`.
3. Wire the UI in `src/MusicDuplicateScanner.ps1` if needed.
4. Run lint + tests locally before opening a PR.
5. Update `CHANGELOG.md` under the `Unreleased` section.

See [CONTRIBUTING.md](https://github.com/Bill-Tetrault/MusicDuplicateScanner/blob/main/CONTRIBUTING.md) for the full contribution guidelines.

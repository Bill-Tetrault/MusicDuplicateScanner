# Architecture

The codebase is split into two layers: a pure-logic **Core module** and a **WPF GUI entry point**. This split is the key architectural decision — it makes the business logic unit-testable without launching a window.

## Directory layout

```
MusicDuplicateScanner/
├── src/
│   ├── MusicDuplicateScanner.Core.psm1   # Pure logic — no UI, no Add-Type
│   └── MusicDuplicateScanner.ps1         # WPF GUI — imports Core, wires events
├── tests/
│   └── MusicDuplicateScanner.Core.Tests.ps1  # Pester 5 test suite (27 tests)
├── lib/
│   └── (TagLibSharp.dll — not bundled, see lib/README.md)
├── docs/
├── wiki/
├── .github/
│   └── workflows/
│       └── ci.yml                        # PSScriptAnalyzer + Pester + smoke test
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── PSScriptAnalyzerSettings.psd1
```

## Core module (`MusicDuplicateScanner.Core.psm1`)

The Core module contains all business logic and has **zero WPF/UI dependencies**. It runs on Windows, Linux, and macOS under PowerShell 7.

### Exported functions

| Function | Purpose |
|---|---|
| `ConvertTo-NormalizedTrackName` | Strips noise tokens from a filename for similarity comparison |
| `Get-JaccardSimilarity` | Computes Jaccard coefficient between two token sets |
| `Get-AudioMetadata` | Reads ID3 tags via TagLibSharp (or returns empty object if unavailable) |
| `Get-DuplicateCandidatePair` | Groups files into candidate pairs by filename and/or tag grouping |
| `Get-ConfidenceScore` | Scores a candidate pair (0–100) from filename sim + tag match + hash |
| `Select-PreferredFile` | Picks which file in a pair to keep based on quality, metadata, recency |
| `Start-DuplicateScanCore` | Orchestrates a full scan; reports progress via a `ConcurrentQueue[string]` |
| `Move-QuarantineBatchCore` | Moves a batch of files to quarantine; reports per-file progress |
| `Get-QuarantineDestinationPath` | Maps an original path to its quarantine-folder equivalent |
| `Get-Settings` / `Save-Settings` | Reads/writes `settings.json` under `%LOCALAPPDATA%` |

## GUI script (`MusicDuplicateScanner.ps1`)

The GUI script is responsible for presentation and event wiring only. It:

1. Loads WPF assemblies (`PresentationFramework`, etc.) via `Add-Type`.
2. Imports `MusicDuplicateScanner.Core.psm1`.
3. Defines the XAML window layout inline.
4. Wires button click handlers, the threshold slider, and the results grid.
5. Launches background runspaces for scan and quarantine operations using `[System.Management.Automation.PowerShell]::Create()` + `BeginInvoke` / `EndInvoke`.
6. Drains progress messages from the Core's `ConcurrentQueue` on a `DispatcherTimer` (200 ms tick) to update the UI without blocking.

## Background processing model

```
UI Thread                         Background Runspace
─────────────────                 ──────────────────────────────
Click "Scan"                  →   Import-Module Core
                                  Start-DuplicateScanCore
                                    ↓ enqueues "PROGRESS:..." messages
DispatcherTimer (200ms)       ←   ConcurrentQueue[string]
  drains queue
  updates progress bar,
  status label, log panel
                              ←   RunspacePool.EndInvoke()
Display results grid
```

This pattern is used for both scanning and quarantine batch moves, ensuring the window never becomes unresponsive.

## Design decisions

### Why PowerShell + WPF instead of a compiled app?

- No build step — clone and run.
- Easier contribution for ops/automation engineers who live in PowerShell.
- Core module is reusable from any PS script without a GUI.

### Why split Core from GUI?

WPF assemblies only load on Windows. Moving all logic into `Core.psm1` means Pester tests can run on Linux/macOS in CI without a display server.

### Why move to quarantine instead of delete?

Permanent deletion is an irreversible action on a file library users care about. The quarantine-with-manifest approach trades a small amount of disk space for the ability to recover from mistakes.

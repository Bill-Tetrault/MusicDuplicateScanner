# Contributing

Thanks for considering a contribution.

## Project layout

- `src/MusicDuplicateScanner.Core.psm1` - pure logic (normalization,
  similarity scoring, confidence scoring, preferred-file selection,
  quarantine path mapping, settings persistence). No WPF/UI code. Runs and
  is unit-tested on Windows, Linux, and macOS.
- `src/MusicDuplicateScanner.ps1` - the WPF GUI entry point. Imports the Core
  module and layers presentation/event-handling on top. Windows-only.
- `tests/` - Pester 5 tests for the Core module.
- `.github/workflows/ci.yml` - lint (PSScriptAnalyzer) + test (Pester) on
  every push/PR, plus a Windows syntax smoke test for the GUI script.

## Local setup

```powershell
# One-time
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Test
Invoke-Pester -Path ./tests -Output Detailed
```

Both commands work on PowerShell 7+ on any OS, since they only touch
`src/MusicDuplicateScanner.Core.psm1` and `tests/`.

## Guidelines

- New business logic goes in `MusicDuplicateScanner.Core.psm1` and gets a
  Pester test in `tests/`. If it can't be unit-tested without opening a
  window, it belongs in the Core module instead of the GUI script.
- Use approved PowerShell verbs (`Get-Verb`) for new functions.
- Run the lint + test commands above before opening a PR; CI enforces both.
- Keep the GUI script's event handlers thin - they should call into Core
  functions or small GUI helper functions, not contain business logic
  inline.
- If you touch the confidence-scoring weights in `Get-ConfidenceDetails`,
  add or update a test in `tests/MusicDuplicateScanner.Core.Tests.ps1` that
  pins the expected score for a representative case.

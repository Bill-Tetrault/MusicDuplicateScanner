# Music Duplicate Scanner

A Windows WPF desktop tool that scans your music library for likely
duplicate files, scores each candidate pair by confidence, and lets you
review, export, and safely quarantine (not permanently delete) the ones you
don't want. Scans MP3, FLAC, WAV, M4A, OGG, WMA, and AAC by default, and the
file types it looks for are fully configurable.

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207-5391FE)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

## Features

- Recursive or top-level scan of a folder for configurable file types
  (defaults to `mp3, flac, wav, m4a, ogg, wma, aac`; set your own
  comma-separated list in the "File types" field).
- Duplicate detection by:
  - Normalized filename similarity (Jaccard token overlap after stripping
    "copy"/"(1)"/track-number/etc. noise).
  - Tag metadata comparison (title, artist, album, track, year, duration) via
    [TagLibSharp](https://github.com/mono/taglib-sharp) - optional but
    recommended.
  - Optional SHA-256 content hashing for exact-match confirmation.
- Weighted confidence score (0-100) per candidate pair with a
  High/Medium/Low recommendation.
- Adjustable confidence threshold slider.
- Sortable results grid; CSV export of the full result set.
- **Quarantine, not delete.** Selected duplicates are moved to a quarantine
  folder (preserving relative subfolder structure) instead of being
  permanently removed. Each run writes an undo manifest; an "Undo Last
  Quarantine" button restores everything from the most recent run.
- Background scanning - the scan and hash phases run off the UI thread with
  a progress bar and live status log, so the window never appears hung
  during a large scan. A Cancel button stops the scan promptly.
- Settings (last-used library path, quarantine path, threshold, options)
  persist between launches.
- Activity log mirrored to disk for after-the-fact review of long scans.

## Requirements

- Windows 10/11 (uses WPF via `System.Windows`; not cross-platform).
- PowerShell 5.1 (built into Windows) or PowerShell 7+.
- .NET Framework 4.6.2+ (present on any current Windows install).
- Optional but recommended: `TagLibSharp.dll` for metadata-based matching.
  See [`lib/README.md`](lib/README.md) for where to get it and where to put
  it. Without it, the scanner still works using filename similarity, file
  size, and hash comparisons alone.

## Getting started

1. Clone or download this repository.
2. (Optional, recommended) Get `TagLibSharp.dll` per
   [`lib/README.md`](lib/README.md) and place it in `lib/` or next to
   `MusicDuplicateScanner.ps1`.
3. Run the GUI:

   ```powershell
   cd src
   .\MusicDuplicateScanner.ps1
   ```

   Or launch straight into a specific library:

   ```powershell
   .\MusicDuplicateScanner.ps1 -LibraryPath 'D:\Music' -QuarantinePath 'D:\Music\_Quarantine' -Threshold 70
   ```

4. If Windows blocks the script (`running scripts is disabled on this
   system`), either unblock the downloaded file:

   ```powershell
   Unblock-File .\MusicDuplicateScanner.ps1
   Unblock-File .\MusicDuplicateScanner.Core.psm1
   ```

   or run PowerShell with a permissive-enough execution policy for the
   session:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\MusicDuplicateScanner.ps1
   ```

## Usage

1. Browse to your music library folder and (optionally) a quarantine
   folder - it defaults to a `_Quarantine` subfolder of the library if left
   blank.
2. Choose whether to scan subfolders and whether to hash all candidate
   pairs (slower, but confirms byte-for-byte matches).
3. Click **Scan for Duplicates**. Progress and a running log appear while
   the scan works in the background; **Cancel Scan** stops it.
4. Review the results grid, sorted by confidence. Adjust the threshold
   slider to focus on higher- or lower-confidence pairs.
5. Check the box next to files you want removed, or use **Select All
   Below Threshold**.
6. Click **Quarantine Selected** to move them out of the library (not
   delete them). If you change your mind, click **Undo Last Quarantine**.
7. Use **Export to CSV** any time to save the full result set for review
   outside the app.

## Architecture

```
src/
├── MusicDuplicateScanner.Core.psm1   # Pure logic - no UI, no Add-Type.
│                                      # Cross-platform, unit-tested.
└── MusicDuplicateScanner.ps1         # WPF GUI - imports Core, wires events.
                                       # Windows-only.
tests/
└── MusicDuplicateScanner.Core.Tests.ps1   # Pester 5 tests for Core.
```

Keeping business logic (`Core.psm1`) separate from presentation (`.ps1`)
is what makes the scoring and matching logic unit-testable at all - the GUI
script depends on WPF assemblies that only load on Windows, but the Core
module has none of that and runs anywhere PowerShell 7 does.

## Development

```powershell
# Install tooling once
Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Test
Invoke-Pester -Path ./tests -Output Detailed
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines and
[`CHANGELOG.md`](CHANGELOG.md) for a detailed history of bugs fixed in the
2.0.0 rewrite (Int32 overflow, a single-group array-concatenation crash, a
TagLib file-handle leak, UI-thread blocking, and unsafe permanent deletion).

## License

[MIT](LICENSE) - see the [`lib/README.md`](lib/README.md) note on why
`TagLibSharp.dll` itself isn't bundled in this repository.

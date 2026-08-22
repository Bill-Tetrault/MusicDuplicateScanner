# FAQ

Common questions and troubleshooting for Music Duplicate Scanner.

---

## Setup

### Do I need to install anything?

No installer or compilation step is needed. PowerShell 5.1 (built into Windows 10/11) and .NET Framework 4.6.2+ (present on any current Windows install) are the only hard requirements. TagLibSharp is optional but recommended — see [Installation](Installation).

### Where do I get TagLibSharp?

Download it from [NuGet](https://www.nuget.org/packages/TagLibSharp/). Rename the `.nupkg` file to `.zip`, extract it, and copy `TagLibSharp.dll` from `lib\netstandard2.0\` to the `lib\` folder next to the repository root (or next to `MusicDuplicateScanner.ps1`). See [`lib/README.md`](https://github.com/Bill-Tetrault/MusicDuplicateScanner/blob/main/lib/README.md) for exact placement instructions.

### I get "running scripts is disabled on this system"

This is a PowerShell execution policy restriction. Two options:

1. **Unblock the files** (one-time, safest): `Unblock-File .\MusicDuplicateScanner.ps1; Unblock-File .\MusicDuplicateScanner.Core.psm1`
2. **Bypass for the session**: `powershell -ExecutionPolicy Bypass -File .\MusicDuplicateScanner.ps1`

Do not set `Set-ExecutionPolicy Unrestricted` machine-wide.

### Does it run on macOS or Linux?

The **GUI** (`MusicDuplicateScanner.ps1`) requires Windows because it uses WPF. However, the **Core module** (`MusicDuplicateScanner.Core.psm1`) has no WPF dependency and runs on any platform supporting PowerShell 7. You can import it directly from a script for headless duplicate detection.

---

## Scanning

### The scan failed instantly with "Library path is empty."

This was a bug in versions prior to v2.0.1 where the background runspace did not correctly receive the library path. Update to v2.0.1 or later.

### Windows-style `Song (1).mp3` copies aren't being detected as duplicates

This was a bug in versions prior to v2.0.1 where the `(1)` suffix was not stripped during normalization. Update to v2.0.1 or later.

### Scanning is very slow

The main performance factor is **SHA-256 hashing**, which reads every byte of every candidate file. On a large library with many candidates, this can take minutes. To speed things up:
- Uncheck **Compute SHA-256 for candidate matches** — filename similarity and tag matching alone are usually sufficient for identifying duplicates.
- Hashing is only performed on candidate pairs (files that already matched by name or tags), not the entire library, but a library with many near-duplicates will still hash many files.

### A file appeared in the results but I know it's not a duplicate

Lower the threshold slider to understand why it scored as a candidate, then raise the threshold to filter it out. If the score is driven by a false filename similarity match, you can safely ignore or uncheck that row — the quarantine operation only affects rows you explicitly select.

### Will it find duplicates in different formats (FLAC, AAC, WAV)?

No. The scanner only processes `.mp3` files. Format-agnostic deduplication is outside the current scope.

---

## Quarantine & Undo

### Are files permanently deleted?

No. Files are **moved** to the quarantine folder — never deleted, never sent to the Recycle Bin. Click **Undo Last Quarantine** to restore everything from the most recent run.

### I accidentally clicked "Undo" — can I redo?

There is no Redo. Only one undo level (the most recent quarantine run) is retained. If you need to re-quarantine, re-run the scan and reselect the files.

### The quarantine folder is inside my library and files are getting re-scanned

Move the quarantine folder outside the library root, or configure the **Quarantine Path** to a location outside the scan root. The app will warn you on startup if the configured quarantine folder is nested inside the library path.

### Can I use a quarantine folder on a different drive?

Yes, but moves across drive boundaries require a full file copy followed by a delete (the OS cannot relink inodes across volumes). This is slower than same-drive moves. On very large files or slow drives, this may be noticeably slower than a same-drive quarantine.

---

## Results & Export

### Can I save results without quarantining anything?

Yes. Click **Export to CSV** at any time to save the full result set — all pairs, all scores, regardless of threshold — without moving any files.

### Where are the activity logs stored?

Logs are written to `%LOCALAPPDATA%\MusicDuplicateScanner\logs\` with timestamp-based filenames (e.g. `2026-08-22_143012.log`). They contain a complete per-file activity record useful for reviewing long scans after the fact.

### Where are settings stored?

`%LOCALAPPDATA%\MusicDuplicateScanner\settings.json`. You can delete this file to reset all settings to defaults.

---

## Contributing

### How do I contribute?

See [CONTRIBUTING.md](https://github.com/Bill-Tetrault/MusicDuplicateScanner/blob/main/CONTRIBUTING.md) for guidelines. In brief: fork, branch, write tests for any Core logic changes, run lint + Pester, and open a PR.

### Can I add support for formats other than MP3?

Yes — this would be a welcome contribution. The Core module's file-discovery step filters for `.mp3`; extending it to accept additional extensions (`.flac`, `.m4a`, `.ogg`) via a parameter is straightforward. TagLibSharp supports all common audio formats, so metadata reading would work without changes to `Get-AudioMetadata`.

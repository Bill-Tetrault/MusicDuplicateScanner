# Changelog

Full version history for Music Duplicate Scanner. Follows [Keep a Changelog](https://keepachangelog.com/) conventions.

---

## v3.0.1

Bug-fix release, found from a real scan log on a large network-drive library.

### Fixed

- Fixed a crash (`Value cannot be null. (Parameter 'collection')`) that hit any scan completing with 0 matches.
- Fixed a misleading `Hash failed for ... : The property 'Hash' cannot be found on this object` log message that masked the real cause (e.g. a transient network-drive read error) during SHA-256 hashing.

See the main repo [CHANGELOG.md](https://github.com/Bill-Tetrault/MusicDuplicateScanner/blob/main/CHANGELOG.md) for full technical detail.

---

## v3.0.0

### Added

- **Configurable file types.** A new "File types" field (GUI) / `-FileExtensions` startup parameter and `FileExtensions` setting let you choose which extensions to scan, comma-separated (e.g. `mp3, flac, wav`). The default is now `mp3, flac, wav, m4a, ogg, wma, aac` instead of MP3-only. TagLibSharp already reads tags for all of these formats without any changes to `Get-AudioMetadata`, and the filename/hash/quarantine logic was already extension-agnostic — only file enumeration was hardcoded to `.mp3`.
- **`ConvertTo-ExtensionFilterList`** (new, exported, unit tested): sanitizes the free-text extension list — strips leading dots/wildcards, lowercases, dedupes, caps at 50 entries, and drops any token that isn't a plain `[a-z0-9]{1,15}` string — before it can reach file enumeration. Runs both at the GUI boundary and again inside `Start-DuplicateScanCore` for defense in depth.
- **`Get-MusicFile`** now takes an `-Extensions` array and matches all of them in a single directory pass via a case-insensitive `HashSet` lookup, avoiding a verified `-Include`/non-recursive footgun (see [Architecture](Architecture) for details).

### Changed

- `settings.json` files from earlier versions are auto-backfilled with the new `FileExtensions` default on load — no migration step needed.

### Notes

- Evaluated jointly as a DevSecOps + Marketing decision: extending this app with configurable audio extensions was chosen over spinning off a separate video/image dedupe app, since video/image matching needs a fundamentally different engine (perceptual hashing, resolution/codec scoring) and a generic rebrand would dilute this app's focused niche. See the main repo `CHANGELOG.md` for the full rationale.

---

## v2.1.0

### Added

- **Prefer subfolder copy on exact hash match.** When two files have equal SHA-256 hashes, the file living directly at the library root is marked for removal in favor of the copy filed into a subfolder. If both (or neither) file is at the root, or hashes differ, the existing quality-based scoring (bitrate → sample rate → size → metadata → recency) applies unchanged. Implemented in `Select-PreferredFile` via a new `-RootPath` parameter.
- **Live quarantine progress bar.** Quarantine moves now run on a background runspace (same pattern as scanning) and report per-file `PROGRESS:<index>:<total>:<message>` lines through a `ConcurrentQueue[string]`. A `DispatcherTimer` drains the queue on the UI thread and updates a determinate progress bar, status label, and log panel in real time. Scan and Undo buttons are disabled during the batch.

---

## v2.0.1

### Fixed

- **Every scan failed with `"Library path is empty."`** even when a valid path was provided. Root cause: the background runspace extracted and dot-sourced `Start-DuplicateScanCore`'s body as raw text, which executed it immediately with all parameters unbound. Fix: `Start-DuplicateScanCore` now lives in `Core.psm1` and is reached by the background runspace via a plain `Import-Module`.
- **Windows-style `(1)` copy-counter duplicates were never detected.** `ConvertTo-NormalizedTrackName` did not strip trailing `(N)`/`[N]` suffixes, so `Song.mp3` and `Song (1).mp3` normalized to different strings and were never paired. Fix: trailing `(N)`/`[N]` (1–2 digits), `- Copy`, and `- Copy (N)` suffixes are now stripped. Four-digit brackets (release years like `(2019)`) are intentionally preserved. Covered by 3 new regression tests.

---

## v2.0.0

Full rewrite for open-source release.

### Architecture

- Split monolithic script into `MusicDuplicateScanner.Core.psm1` (pure logic, cross-platform) and `MusicDuplicateScanner.ps1` (WPF GUI, Windows-only).
- Added Pester 5 test suite (27 tests) runnable on Windows, Linux, and macOS.
- Added GitHub Actions CI: PSScriptAnalyzer + Pester on push/PR, Windows syntax smoke test.

### Fixed

- **Int32 overflow in `Select-PreferredFile`:** `[datetime]::ToFileTimeUtc()` values are 64-bit; casting to `[int]` threw on real-world files. All scoring accumulators are now `[long]`.
- **Single-group array-concatenation crash:** `@($byName + $byMetadata)` threw `"op_Addition"` when `Group-Object` returned a scalar instead of an array. Fixed by forcing both sides to arrays before concatenating.
- **TagLibSharp file handle leak:** `Get-AudioMetadata` now disposes `TagLib.File` in a `finally` block.
- **UI thread blocking:** Scanning and hashing now run on a background runspace; the window stays responsive with a live progress bar and a working Cancel button.
- **Permanent deletion:** Replaced with quarantine move preserving folder structure, with a per-run undo manifest and **Undo Last Quarantine** button.
- **`Join-Path` drive-resolution failures:** Quarantine paths are now composed with string/regex logic instead of provider-aware `Join-Path`.

### Added

- Persisted settings (`%LOCALAPPDATA%\MusicDuplicateScanner\settings.json`).
- Activity log mirrored to disk (`%LOCALAPPDATA%\MusicDuplicateScanner\logs\`).
- Guardrail warning when quarantine folder is nested inside the library path.
- Optional `-LibraryPath`, `-QuarantinePath`, `-Threshold` startup parameters.
- Light theme (previous dark theme had poor contrast on inputs and grid).

---

## v1.0.0

Initial internal version. WPF duplicate scanner for MP3 libraries with filename + TagLibSharp metadata matching, confidence scoring, CSV export, and permanent deletion of selected duplicates.

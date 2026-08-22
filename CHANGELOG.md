# Changelog

## 3.0.0

Configurable file-type scanning, evaluated jointly from a DevSecOps and
Marketing perspective before implementation (see rationale below).

### Added
- **Scan for any audio file type, not just MP3.** A new "File types" field
  (GUI) / `-FileExtensions` parameter and `FileExtensions` setting lets you
  choose which extensions to scan, comma-separated (e.g. `mp3, flac, wav`).
  The default is now `mp3, flac, wav, m4a, ogg, wma, aac` instead of
  MP3-only - existing users will see the broader set on first launch after
  updating, and can narrow it back down to `mp3` in Settings if they only
  want MP3s. TagLibSharp already reads tags for all of these formats
  without any code changes to `Get-AudioMetadata`, and the
  filename/hash/quarantine logic was already extension-agnostic.
- New `ConvertTo-ExtensionFilterList` function (Core module, exported and
  unit tested) parses and validates the free-text extension list: it
  strips leading dots/wildcards, lowercases, dedupes, caps the list at 50
  entries, and drops any token that isn't a plain `[a-z0-9]{1,15}` string
  before it can reach file enumeration - so stray punctuation, path
  separators, or `..` segments pasted into the field can never become a
  filesystem filter. Sanitization happens both at the GUI boundary and
  again inside `Start-DuplicateScanCore` (defense in depth, since the Core
  module is a public entry point other scripts could call directly).
- `Get-MusicFile` now takes an `-Extensions` array and matches all of them
  in a single directory pass using a case-insensitive `HashSet` lookup on
  each file's extension, rather than `-Include`, which was verified (via a
  standalone empirical test) to silently return zero results for
  non-recursive multi-pattern scans unless the path ends in a trailing
  wildcard - a real PowerShell footgun this design avoids entirely.

### Changed
- `settings.json` files from earlier versions are auto-backfilled with the
  new `FileExtensions` default the first time they're loaded (existing
  `Import-AppSettings` merge logic already did this for any missing key,
  no migration code needed).

### Why extend this app instead of a separate video/image app
- **DevSecOps view:** video and image dedupe need a different matching
  model entirely (perceptual/frame hashing, resolution/codec scoring, much
  larger file I/O) that the current byte-hash + tag-metadata engine and
  background-runspace sizing weren't built for. Bolting that on here would
  mean two half-tested matching engines in one codebase. A configurable
  extension list for audio formats TagLibSharp already understands is a
  small, fully-tested, no-new-dependency change by comparison.
- **Marketing view:** "Music Duplicate Scanner" has a defensible niche
  (tag-aware, bitrate-aware audio dedupe) that a generic rebrand would
  dilute into a crowded field of general file-dedupe tools. Widening to
  all common audio formats is a natural, marketable extension of the same
  promise ("dedupe your whole music library, not just MP3s"); video/image
  dedupe is a genuinely different product for a different buyer, worth a
  separate app if pursued later rather than diluting this one now.

## 2.1.0

Two feature additions on top of the 2.0.1 hotfix.

### Added
- **Prefer the copy in a subfolder over one sitting at the library root when
  two files are an exact (hash-verified) match.** `Select-PreferredFile`
  now accepts a `-RootPath` parameter. When both candidates were hashed
  (SHA256, via the "Compute SHA256 for candidate matches" option) and their
  hashes are equal, quality-based scoring is skipped (byte-identical files
  are equally good by definition) and the file living directly at the
  scanned library root is marked for deletion in favor of the copy filed
  into a subfolder. If both or neither file is at the root, or the hashes
  differ, or `-RootPath` is not supplied, behavior falls through unchanged
  to the existing bitrate/sample-rate/size/metadata/recency scoring. All
  property access uses the existing `Get-PropertyValue` helper so this is
  safe under `Set-StrictMode -Version Latest` even for fixtures/objects
  that never had a `Hash` or `Directory` property set.
- **Live progress while moving files to quarantine.** Quarantine moves used
  to run as a single blocking loop on the UI thread with no feedback until
  a final "Moved/Failed" dialog. The move loop was extracted into a new
  pure-logic `Move-QuarantineBatchCore` function (Core module, unit
  tested) that reports `PROGRESS:<index>:<total>:<message>` lines through
  a `ConcurrentQueue[string]`. The GUI now runs this on a background
  `[System.Management.Automation.PowerShell]` runspace - the same pattern
  already used for scanning - while a 200ms `DispatcherTimer` drains the
  queue on the UI thread, updating a determinate progress bar
  (`n / total`), the status label, and the log per file, without blocking
  the window. The Scan and Undo buttons are disabled for the duration and
  re-enabled when the batch completes.

## 2.0.1

Hotfix for two real bugs surfaced during actual use of 2.0.0, both found by
reproducing the reported failure directly rather than only re-reading code.

### Fixed
- **Every scan failed instantly with `Exception calling "EndInvoke" ...
  "Library path is empty."` even with a valid path typed in.** Root cause:
  `Start-BackgroundScan` extracted `Start-DuplicateScanCore`'s body as text
  via `(Get-Item Function:...).ScriptBlock.ToString()` and dot-sourced it
  inside the background runspace with `. ([scriptblock]::Create($func))`.
  That extraction only captures the scriptblock's `param(...)` block and
  statements, not a `function Name { ... }` wrapper - dot-sourcing it
  therefore executed the body immediately, once, with every parameter
  unbound (so `$RootPath` was empty), instead of defining a callable
  function. The real `Start-DuplicateScanCore -RootPath $RootPath ...` call
  written afterward in the same script never even ran. **Fix:**
  `Start-DuplicateScanCore` now lives in `MusicDuplicateScanner.Core.psm1`
  and is exported; the background runspace reaches it with a plain
  `Import-Module $CorePath -Force`, so no function-to-text transplant is
  needed at all. Verified with an end-to-end reproduction through the same
  `PowerShell.Create()` / `BeginInvoke` / `EndInvoke` path the GUI uses.
- **Windows-style `(1)` copy-counter duplicates were never detected.**
  `Get-DuplicateCandidatePair` groups files by exact `BaseNameNormalized`
  string equality, but `ConvertTo-NormalizedTrackName` didn't strip trailing
  copy-counter suffixes, so `Song.mp3` (-> `song`) and `Song (1).mp3`
  (-> `song 1`) normalized to different strings and were silently never
  paired as candidates - despite this being arguably the single most common
  real-world duplicate pattern (Windows' own auto-numbering when a file is
  copied into the same folder). Found while building a reproduction for the
  bug above, using two files named this way. **Fix:** trailing `(N)`/`[N]`
  (1-2 digits), `- Copy`, and `- Copy (N)` suffixes are now stripped before
  the general bracket-collapse step. A 4-digit trailing bracket, e.g. a
  release year like `(2019)`, deliberately still is not stripped, per the
  existing intentional behavior that preserves years as meaningful tokens.
  Covered by 3 new regression tests, including one that pins the year-
  preservation case so this fix can't regress it later.

## 2.0.0

Full rewrite for open-source release.

### Architecture
- Split into a pure, unit-testable `MusicDuplicateScanner.Core.psm1` module
  (normalization, similarity, confidence scoring, preferred-file selection,
  quarantine path mapping, settings persistence) and a WPF GUI entry point
  (`MusicDuplicateScanner.ps1`) that only handles presentation and event
  wiring. The previous single-file version mixed both, which made it
  impossible to unit-test without launching a window.
- Added a Pester test suite (27 tests) covering the Core module, runnable
  on Windows, Linux, and macOS.
- Added a GitHub Actions workflow: PSScriptAnalyzer lint + Pester tests on
  every push/PR, plus a Windows syntax smoke test for the GUI script.

### Fixed
- **Int32 overflow in `Select-PreferredFile`.** Casting
  `[datetime]::ToFileTimeUtc()` (a 64-bit tick count, e.g.
  `134317609806497344`) to `[int]` threw `"Value was either too large or
  too small for an Int32"` on real-world files. All scoring accumulators
  are now explicitly `[long]`, and recency is scored from `.Ticks` scaled
  down rather than a raw file-time cast to `Int32`. Covered by a regression
  test.
- **Latent crash when exactly one duplicate group is found.**
  `Get-DuplicateCandidatePair` (previously inline in `Start-DuplicateScan`)
  used `@($byName + $byMetadata)`. When `Group-Object` returns exactly one
  group, PowerShell unwraps it to a scalar `[GroupInfo]` instead of an
  array, and `+` between two `GroupInfo` objects throws `"does not contain
  a method named 'op_Addition'"`. Found via unit testing, not previously
  reported. Fixed by forcing both sides to arrays before concatenating.
- **TagLibSharp file handle leak.** `Get-AudioMetadata` now disposes the
  `TagLib.File` in a `finally` block, so a thrown exception between
  `Create()` and the original `Dispose()` call no longer leaks an open file
  handle across a large library scan.
- **UI froze for the entire scan duration.** On an 8,409-file library, a
  prior version blocked the WPF UI thread for ~2 hours during hashing
  (visible in earlier session logs), making the app look hung. Scanning and
  hashing now run on a background runspace with progress messages drained
  by a `DispatcherTimer`, so the window stays responsive, shows live
  status, and has a working Cancel button.
- **Permanent deletion.** Replaced with a quarantine move that preserves
  original folder structure, records an undoable CSV manifest per run, and
  offers an "Undo Last Quarantine" button.
- **`Join-Path` drive-resolution failures.** Quarantine destination paths
  are now composed with explicit string/regex logic instead of
  provider-aware `Join-Path`, avoiding `"Cannot find drive"` errors when a
  drive letter isn't a currently mapped PSDrive.

### Added
- Persisted settings (library path, quarantine path, threshold, options)
  under `%LOCALAPPDATA%\MusicDuplicateScanner\settings.json`, restored on
  next launch.
- Activity log mirrored to disk under
  `%LOCALAPPDATA%\MusicDuplicateScanner\logs\`, useful for reviewing
  multi-hour scans after the fact.
- Guardrail warning when the quarantine folder is nested inside the
  library path being scanned (avoids re-scanning already-quarantined
  files).
- Optional `-LibraryPath`, `-QuarantinePath`, `-Threshold` startup
  parameters for scripted/CLI-adjacent launches.
- Light theme (previous dark theme had poor contrast on inputs, checkboxes,
  grid, and log panel).

## 1.0.0

Initial internal version: WPF duplicate scanner for MP3 libraries with
filename + TagLibSharp metadata matching, confidence scoring, CSV export,
and permanent deletion of selected duplicates.

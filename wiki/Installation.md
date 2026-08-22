# Installation

Music Duplicate Scanner is a pure-PowerShell / WPF application. There is nothing to compile and no installer. This page covers every prerequisite and the two common setups (with and without TagLibSharp).

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | WPF requires Windows; the tool is not cross-platform |
| PowerShell | 5.1 or 7+ | PS 5.1 is built into Windows; PS 7 is optional but recommended |
| .NET Framework | 4.6.2+ | Present on any current Windows install; nothing to install |
| TagLibSharp | 2.x | **Optional but recommended** — enables metadata-based matching |

## Step 1 — Get the code

**Option A — Clone**

```powershell
git clone https://github.com/Bill-Tetrault/MusicDuplicateScanner.git
cd MusicDuplicateScanner
```

**Option B — Download ZIP**

1. Go to the [Releases page](https://github.com/Bill-Tetrault/MusicDuplicateScanner/releases) and download the latest source archive.
2. Extract it anywhere (e.g. `C:\Tools\MusicDuplicateScanner`).

## Step 2 — (Optional, recommended) Add TagLibSharp

TagLibSharp enables reading ID3 tag metadata (title, artist, album, track, year, duration). Without it, the scanner still works via filename similarity, file size, and SHA-256 hash — but tag-based matching is the most reliable strategy for music libraries.

1. Download `TagLibSharp.dll` from [NuGet](https://www.nuget.org/packages/TagLibSharp/) (click **Download package**, rename the `.nupkg` to `.zip`, and extract it; the DLL is under `lib\netstandard2.0\`).
2. Place `TagLibSharp.dll` in either:
   - `lib\TagLibSharp.dll` (relative to the repository root), **or**
   - next to `src\MusicDuplicateScanner.ps1`.
3. See [`lib/README.md`](https://github.com/Bill-Tetrault/MusicDuplicateScanner/blob/main/lib/README.md) for the exact expected path and why the DLL isn't bundled.

## Step 3 — First launch

```powershell
cd src
.\MusicDuplicateScanner.ps1
```

### Execution policy errors

If Windows blocks the script (`running scripts is disabled on this system`):

**Unblock the downloaded files** (one-time, recommended):

```powershell
Unblock-File .\MusicDuplicateScanner.ps1
Unblock-File .\MusicDuplicateScanner.Core.psm1
```

**Or bypass policy for a single session**:

```powershell
powershell -ExecutionPolicy Bypass -File .\MusicDuplicateScanner.ps1
```

> ⚠️ Do not set `Set-ExecutionPolicy Unrestricted` machine-wide. Use `Bypass` per-session or `Unblock-File` per-file.

## Step 4 — Verify

The window opens, the title bar shows **Music Duplicate Scanner**, and the status bar reads `Ready.` If TagLibSharp loaded successfully, the log panel will note it on startup. If the DLL wasn't found, the log will say metadata matching is disabled — this is not an error; the tool will continue with filename and hash matching only.

# CLI Parameters

While Music Duplicate Scanner is primarily a GUI application, the entry-point script (`MusicDuplicateScanner.ps1`) accepts several startup parameters. These are useful for:

- Scripted or batch launches
- Pinning a specific library so the GUI opens pre-configured
- CI/automation scenarios where you want to pre-seed settings

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-LibraryPath` | `string` | *(last saved setting)* | Absolute path to the music library root to pre-populate the Library Path field |
| `-QuarantinePath` | `string` | *(last saved setting or `<library>/_Quarantine`)* | Absolute path to the quarantine destination |
| `-Threshold` | `int` (0–100) | *(last saved setting or 70)* | Confidence threshold to pre-set the slider |
| `-FileExtensions` | `string` | *(last saved setting or `mp3, flac, wav, m4a, ogg, wma, aac`)* | **New in v3.0.0.** Comma-separated extension list to pre-populate the "File types" field, e.g. `'mp3,flac'` |

## Examples

**Open with a specific library:**

```powershell
.\MusicDuplicateScanner.ps1 -LibraryPath 'D:\Music'
```

**Open fully pre-configured:**

```powershell
.\MusicDuplicateScanner.ps1 \
    -LibraryPath 'D:\Music' \
    -QuarantinePath 'E:\Music_Quarantine' \
    -Threshold 80 \
    -FileExtensions 'mp3,flac,wav'
```

**Bypass execution policy for a single session:**

```powershell
powershell -ExecutionPolicy Bypass -File .\MusicDuplicateScanner.ps1 \
    -LibraryPath 'D:\Music' -Threshold 75
```

**From PowerShell 7:**

```powershell
pwsh -File .\MusicDuplicateScanner.ps1 -LibraryPath 'D:\Music'
```

## Settings persistence

Settings (library path, quarantine path, threshold, file extensions, checkbox states) are written to:

```
%LOCALAPPDATA%\MusicDuplicateScanner\settings.json
```

Parameters passed at startup override the saved values for that session. They are also written back to `settings.json`, so the next launch will remember them even if you don't pass them again.

## No headless/unattended mode

There is currently no `-Headless` or `-AutoScan` flag. The application always opens a window. For fully unattended duplicate detection, consider using the `Core` module directly from a script:

```powershell
Import-Module .\src\MusicDuplicateScanner.Core.psm1
$results = Start-DuplicateScanCore -RootPath 'D:\Music' -Recurse -ComputeHash `
    -Extensions @('mp3', 'flac', 'wav')
$results | Export-Csv -Path 'duplicates.csv' -NoTypeInformation
```

The Core module has no WPF dependency and runs on any platform that supports PowerShell 7. `-Extensions` is optional — omit it to fall back to the default set (`mp3, flac, wav, m4a, ogg, wma, aac`). Any values you pass are re-validated internally via `ConvertTo-ExtensionFilterList` (added in v3.0.0), so this is safe to call with unsanitized input from your own scripts.

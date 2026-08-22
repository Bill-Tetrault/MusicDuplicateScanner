# Quarantine & Undo

Music Duplicate Scanner is **non-destructive by design**. No file is ever permanently deleted during normal operation — selected duplicates are moved to a quarantine folder, and every quarantine run writes an undo manifest so the entire batch can be reversed with one click.

## How quarantine works

1. You select one or more files in the results grid and click **Quarantine Selected**.
2. Each file is **moved** (not copied-then-deleted; not sent to the Recycle Bin — moved directly) to the quarantine folder.
3. The **original subfolder structure is preserved**. If the library is `D:\Music` and the file is `D:\Music\Rock\Artist\Song.mp3`, it lands at `<QuarantinePath>\Rock\Artist\Song.mp3`.
4. A progress bar tracks each file move in real time (added in v2.1.0). Scan and Undo buttons are disabled during the move batch.
5. A summary dialog reports success and failure counts when the batch finishes.

## The undo manifest

Before moving any files, the scanner writes a CSV manifest to:

```
%LOCALAPPDATA%\MusicDuplicateScanner\undo_manifest.csv
```

The manifest has two columns:

| Column | Content |
|---|---|
| `QuarantinePath` | Where the file was moved to |
| `OriginalPath` | Where the file came from |

Each quarantine run **overwrites** the previous manifest. Only one undo level is retained — the most recent run.

## Undoing a quarantine

1. Click **Undo Last Quarantine** in the toolbar.
2. The scanner reads `undo_manifest.csv` and moves each file from `QuarantinePath` back to `OriginalPath`.
3. If the original directory no longer exists, it is recreated automatically.
4. A summary dialog reports how many files were restored.

> ⚠️ If you manually delete files from the quarantine folder after a run, those files cannot be restored by Undo. The manifest will report them as failures.

## Quarantine path recommendations

- Place the quarantine folder **outside** the library root (e.g. `D:\Music_Quarantine` rather than `D:\Music\_Quarantine`). If it is nested inside the library, the app warns you, because quarantined files could be re-scanned on the next run.
- Keep the quarantine folder on the same drive as the library when possible — file moves within the same volume are instant (no byte copying); cross-drive moves require a full copy-then-delete.

## Manually inspecting the quarantine

The quarantine folder is a normal folder. You can open it in Explorer, play files, and manually restore them by dragging them back. The subfolder structure mirrors your library exactly, so it is easy to see where each file belongs.

## Activity log

Every quarantine run (and scan) is also mirrored to the disk log at:

```
%LOCALAPPDATA%\MusicDuplicateScanner\logs\
```

Log files are named by timestamp (e.g. `2026-08-22_143012.log`) and contain the full per-file activity. These are useful for reviewing what happened after a multi-hour scan or quarantine batch.

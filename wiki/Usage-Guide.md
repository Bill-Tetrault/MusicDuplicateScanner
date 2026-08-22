# Usage Guide

This page walks through the GUI from start to finish for a typical scan-review-quarantine workflow.

## 1 — Set paths

| Field | Description |
|---|---|
| **Library Path** | Root folder of your music library. The scanner recurses subdirectories unless you uncheck "Include subfolders". |
| **Quarantine Path** | Where duplicates are moved. Defaults to `<library>/_Quarantine` if left blank. |

Click **Browse** next to each field, or type paths directly. The quarantine folder does not need to exist — it is created automatically.

> ⚠️ Do not place the quarantine folder _inside_ the library path. If you do, the app will warn you before scanning, because quarantined files would otherwise be re-scanned on the next run.

## 2 — Configure options

- **File types** (added in v3.0.0) — A comma-separated list of extensions to scan, e.g. `mp3, flac, wav`. Defaults to `mp3, flac, wav, m4a, ogg, wma, aac`. Leading dots, wildcards, and extra whitespace are tolerated and cleaned up automatically; entries that aren't valid extensions are dropped rather than blocking the scan. If you clear the field entirely or leave only invalid entries, the scanner falls back to the default list rather than matching zero (or every) file.
- **Include subfolders** — Recursively scans all subdirectories. Uncheck to scan only the top-level folder.
- **Compute SHA-256 for candidate matches** — Hashes every candidate pair after filename/tag comparison. Slower (especially on large libraries), but confirms exact byte-for-byte matches and enables the "prefer the filed copy over the root copy" logic introduced in v2.1.0.

## 3 — Set the confidence threshold

The **Confidence Threshold** slider (0–100) controls the minimum score a pair must reach to appear in the results grid. The default is **70**.

- Raise the threshold (e.g. 85–95) to see only high-confidence matches — fewer results, less review work.
- Lower it (e.g. 50–60) to surface borderline candidates — more review needed, but catches near-duplicates.

See [Confidence Scoring](Confidence-Scoring) for how scores are calculated.

## 4 — Scan

Click **Scan for Duplicates**. While scanning:

- The progress bar and status label update in real time.
- The activity log panel streams per-file status messages.
- **Cancel Scan** stops the background worker promptly. Any partial results are discarded.

Scan time depends on library size and whether SHA-256 hashing is enabled. A 5,000-file library without hashing typically completes in under a minute.

## 5 — Review results

The results grid shows one row per candidate pair with these columns:

| Column | Meaning |
|---|---|
| File A / File B | Paths of the two candidate files |
| Confidence | 0–100 score |
| Recommendation | High / Medium / Low |
| Filename Sim | Normalized filename similarity (0–1) |
| Tag Match | Number of matching tag fields |
| Hash Match | ✓ if SHA-256 hashes are equal |
| Preferred | Which file to **keep** (the other is the suggested quarantine target) |

Click any column header to sort. Adjust the **Threshold** slider to filter the grid live without re-scanning.

## 6 — Select files to quarantine

- Check the box in the leftmost column for individual rows.
- Use **Select All Below Threshold** to bulk-select every row below the current threshold.
- The **Preferred** column indicates which file the scorer recommends keeping; the checkbox pre-selects the other one.

## 7 — Quarantine

Click **Quarantine Selected**. Each selected file is _moved_ (not deleted) to the quarantine folder, preserving the original subfolder structure. A progress bar tracks the batch move in real time.

A summary dialog reports how many files moved and how many failed.

## 8 — Undo

If you change your mind, click **Undo Last Quarantine**. The undo manifest from the most recent quarantine run is read, and every file is moved back to its original location. See [Quarantine & Undo](Quarantine-and-Undo) for full details.

## 9 — Export to CSV

Click **Export to CSV** at any time to save the full result set (all rows, regardless of threshold) for review outside the app.

# Confidence Scoring

Every candidate pair is assigned a **confidence score from 0 to 100** that represents how likely the two files are genuine duplicates. This page explains how pairs are identified, how each signal contributes to the score, and how the final recommendation is assigned.

## Step 1 — Candidate pair identification

Before scoring, the scanner must decide which pairs are worth comparing. It uses two grouping strategies:

### Filename normalization

`ConvertTo-NormalizedTrackName` strips noise tokens before comparing:

- Leading track numbers (e.g. `01 -`, `02.`)
- Parenthetical/bracketed copy-counter suffixes: `(1)`, `[2]`, `- Copy`, `- Copy (3)`
- Common edition markers: `(Explicit)`, `[Remaster]`, `[Live]`, etc.
- Punctuation, extra whitespace

Files whose normalized base names match exactly are grouped as candidates. This catches the most common real-world duplicate pattern: Windows' own `Song (1).mp3` auto-numbering.

> Note: A four-digit trailing bracket (e.g. `(2019)`) is intentionally **not** stripped — release years are meaningful tokens.

### Tag-based grouping

When TagLibSharp is available, files are also grouped by matching `title + artist` tag pairs. A file may appear in both a filename group and a tag group; the pair is deduplicated before scoring.

## Step 2 — Signal weights

Each signal contributes a weighted component to the 0–100 score:

| Signal | Weight | How it's measured |
|---|---|---|
| Filename similarity | 40% | Jaccard coefficient of normalized token sets |
| Tag metadata | 35% | Number of matching fields out of: title, artist, album, track, year, duration (±2 s) |
| SHA-256 hash | 25% | Exact match = full 25 pts; hash not computed = 0 pts (not penalized) |

**Formula:**

```
Score = (FilenameSim × 40) + (TagMatchRatio × 35) + (HashBonus × 25)
```

Where `TagMatchRatio = matchingFields / totalComparableFields` and `HashBonus = 1` if hashes match, `0` otherwise (or if hashing was not enabled).

## Step 3 — Recommendation tiers

| Score | Recommendation | Meaning |
|---|---|---|
| 85–100 | **High** | Very likely a duplicate; safe to quarantine with minimal review |
| 65–84 | **Medium** | Probable duplicate; spot-check before quarantining |
| 0–64 | **Low** | Borderline; manual review recommended |

The default threshold slider value of **70** shows all Medium and High confidence pairs by default.

## Step 4 — Preferred file selection

For each pair, `Select-PreferredFile` picks which file to **keep** and marks the other as the quarantine candidate. The decision is based on:

1. **Exact hash match + root vs. subfolder position** (v2.1.0+): If both files were hashed and hashes are equal, the file at the library root is marked for removal in favor of the subfolder copy (a properly organized library should not have files at the root).
2. **Audio quality**: Higher bitrate, then higher sample rate, then larger file size.
3. **Metadata completeness**: More non-empty tag fields wins.
4. **Recency**: More recently modified file is preferred if all else is equal.

This ordering is intentional: quality beats organization, which beats completeness, which beats recency.

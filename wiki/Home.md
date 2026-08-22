# Music Duplicate Scanner — Wiki

Welcome to the **MusicDuplicateScanner** wiki. Use the sidebar (or the links below) to navigate to the topic you need.

## Pages

| Page | What you'll find |
|---|---|
| [Home](Home) | This page — overview and navigation |
| [Installation](Installation) | Prerequisites, getting TagLibSharp, and first launch |
| [Usage Guide](Usage-Guide) | Step-by-step walkthrough of the GUI |
| [Confidence Scoring](Confidence-Scoring) | How pairs are detected and scored |
| [Quarantine & Undo](Quarantine-and-Undo) | How the quarantine system works and how to undo |
| [CLI Parameters](CLI-Parameters) | Startup flags for scripted/headless launches |
| [Architecture](Architecture) | Code layout, Core/GUI split, and design decisions |
| [Development](Development) | Local setup, lint, Pester tests, CI pipeline |
| [Changelog](Changelog) | Version history (v1.0.0 → v3.0.0) |
| [FAQ](FAQ) | Common questions and troubleshooting |

## What is Music Duplicate Scanner?

Music Duplicate Scanner is a Windows WPF desktop application written in PowerShell that finds likely-duplicate audio files in your library, scores each candidate pair by confidence, and lets you **quarantine** (not permanently delete) the ones you want removed — with a one-click undo. As of **v3.0.0**, the file types it scans are configurable — it defaults to `mp3, flac, wav, m4a, ogg, wma, aac`, and you can narrow or widen that list yourself.

### Key properties

- **Non-destructive by design.** Files are moved to a quarantine folder that preserves your original subfolder structure. A per-run undo manifest lets you restore everything.
- **Three detection strategies.** Filename similarity, tag metadata, and optional SHA-256 hash comparison — all combined into a single weighted confidence score.
- **Configurable file types (v3.0.0+).** Not limited to MP3 — set any comma-separated extension list in the "File types" field, sanitized and validated before it ever reaches the filesystem.
- **Background processing.** Scanning and hashing run off the UI thread. The window stays responsive with a live progress bar and a Cancel button.
- **Settings persist.** Library path, quarantine path, threshold, and options are saved between launches under `%LOCALAPPDATA%\MusicDuplicateScanner\`.
- **Live quarantine progress.** File moves report per-file status in a determinate progress bar, so you know exactly where a large batch stands.

## Quick Start

```powershell
cd src
.\MusicDuplicateScanner.ps1
```

See [Installation](Installation) for full prerequisites and [Usage Guide](Usage-Guide) for a step-by-step walkthrough.

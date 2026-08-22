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
| [Changelog](Changelog) | Version history (v1.0.0 → v2.1.0) |
| [FAQ](FAQ) | Common questions and troubleshooting |

## What is Music Duplicate Scanner?

Music Duplicate Scanner is a Windows WPF desktop application written in PowerShell that finds likely-duplicate `.mp3` files in your library, scores each candidate pair by confidence, and lets you **quarantine** (not permanently delete) the ones you want removed — with a one-click undo.

Key properties:

- **Non-destructive by design.** Files are moved to a quarantine folder that preserves your original subfolder structure. A per-run undo manifest lets you restore everything.
- **Three detection strategies.** Filename similarity, ID3 tag metadata, and optional SHA-256 hash comparison — all combined into a single weighted confidence score.
- **Background processing.** Scanning and hashing run off the UI thread. The window stays responsive with a live progress bar and a Cancel button.
- **Settings persist.** Library path, quarantine path, threshold, and options are saved between launches under `%LOCALAPPDATA%\MusicDuplicateScanner\`.

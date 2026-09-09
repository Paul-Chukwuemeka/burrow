# Burrow

A minimal, fast e-book reader for Android. Supports EPUB, PDF, TXT, CBZ, and CBR formats.

## Features

- **Two-phase import** — Books appear instantly with filename titles; metadata (title, author, cover, description) extracts in the background
- **Reader** — EPUB reflow with adjustable font/size/theme, PDF native rendering, TXT with pagination
- **Library** — Grid/list view, sort by title/recent/added, filter by format/reading status/genre/series
- **Collections & Smart Groups** — Organize books manually or by rules (unread, finished, etc.)
- **Dictionary** — Offline word lookup via Open English WordNet (downloaded on first use)
- **Stats** — Reading activity, genre breakdown, heatmap
- **Backup/Restore** — Export/import library as JSON

## Tech Stack

- Flutter + Dart
- Drift (SQLite) for persistence
- Material 3 Expressive design
- Background metadata extraction via isolates

## Building

```bash
# Debug
flutter run

# Release (split by ABI — recommended)
flutter build apk --release --split-per-abi

# Output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

## Install via ADB

```bash
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

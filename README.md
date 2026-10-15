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

## Content engine

All parsing and metadata extraction runs in a single **Rust engine** (native,
via `flutter_rust_bridge`; see `rust/`). It handles every supported format —
EPUB, TXT, CBZ, CBR (via the `rars` crate), and a PDF metadata stub. There is
no Dart parser, no engine flag, and no fallback: `LibraryService.epubEngine`
always resolves to the Rust engine, and a failed `RustLib.init()` surfaces FFI
errors to the caller (placeholder UI, retryable metadata) instead of switching
engines.

## Platform support / known issues

The native `.so` is currently built for Android only (Gradle `cargo-ndk` task).
**iOS has no Rust `.so` packaged, so with the fallback removed, reading
hard-fails on iOS until a cargokit/FFI packaging step lands.**

## Install via ADB

```bash
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

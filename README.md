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

## EPUB engine

EPUB parsing and metadata extraction default to the **Rust engine** (native,
via `flutter_rust_bridge`; see `rust/`). The pure-Dart parser remains
available as a reversible fallback — no code revert needed to switch back:

```dart
await library.saveEpubEngine('dart'); // back to the Dart engine
await library.saveEpubEngine('rust'); // back to the Rust default
```

The choice persists under `burrow.epub.engine.v1` and defaults to `rust`
when unset.

If the native library fails to load (`RustLib.init()` throws), the app falls
back to the Dart engine automatically — the EPUB path is never bricked. The
native `.so` is currently built for Android only (`cargo-ndk` Gradle task);
**iOS packaging is out of scope for Phase A** (no Xcode runner wired up yet),
so iOS always runs on the Dart engine until that follow-up lands.

## Install via ADB

```bash
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

# burrow — Onboarding Redesign Plan

**Status:** Draft
**Date:** 2026-09-11
**Author:** Project Manager Agent

---

## Current State

The onboarding flow lives in `lib/screens/onboarding_screen.dart` (1058 lines) as a
5-page `PageView`:

| Page | Purpose |
|------|---------|
| 0 — Welcome | "burrow" wordmark, "a cozy den for all your books.", CTA: "Tuck in" |
| 1 — Permission | Storage access request, folder scan option, skip |
| 2 — Format Selection | Toggle chips for EPUB/TXT/PDF/CBZ/CBR |
| 3 — Preferences | App theme grid (Light/Dark/OLED) |
| 4 — Import/Scan | Device scan, progress bar, results, "Add your first book" |

**What works well:**
- Clean visual identity with the den graphic and morphing stage container
- `_Squishy` press animation adds tactile personality
- Format chips use format-specific tonal colors (consistent with library)
- Scan is deferred to the final page so earlier steps feel calm
- Test coverage: 8 tests in `test/onboarding_test.dart` covering happy path,
  skip, back, permission denial, folder scan, and first-launch gate

**Known pain points:**
1. All 1058 lines in one file — mixing UI, state, scan logic, and import orchestration
2. No way to re-enter onboarding or revisit preferences from settings
3. Format selection and theme feel like tangential setup — not core to "get to your first book"
4. No educational moment — user doesn't learn *why* burrow is different until they're already in
5. The "skip" path dumps you on an empty import page with no guidance
6. No analytics or funnel visibility — can't measure where users drop off
7. Single monolithic widget makes A/B testing different flows impossible

---

## Redesign Goals

| # | Goal | Metric |
|---|------|--------|
| G1 | Reduce time-to-first-book | Median < 30s from install to first opened book |
| G2 | Increase onboarding completion rate | > 85% reach LibraryScreen |
| G3 | Improve code maintainability | Extract into ≤ 200-line sub-widgets + a flow controller |
| G4 | Make preferences revisitable | Add "Onboarding" entry in SettingsScreen |
| G5 | Surface app personality earlier | Welcome page communicates value prop in < 3s |
| G6 | Support A/B testing | Flow is data-driven, pages are independently swappable |

---

## Proposed Flow (6 steps, 2 tracks)

### Track A: "Quick Start" (default, minimal friction)

```
Welcome → Permission → Format → Import → Done
```

### Track B: "Personalize" (opt-in, richer setup)

```
Welcome → Permission → Format → Theme → Typography → Import → Done
```

The user chooses between tracks on the Permission page via a subtle toggle
or by the default being Quick Start with a "Customize more" link.

### Step-by-step spec

#### Step 0 — Welcome (unchanged, polish only)

- Keep the wordmark + den graphic + "Tuck in" CTA
- Add a subtle tagline rotation or animated illustration to reinforce "cozy den" brand
- The "Skip" button still jumps to the import page

**Changes:**
- Extract `_denGraphic` and `_StageSpec` into `widgets/onboarding/`
- Add semantic labels to the decorative graphic for screen readers

#### Step 1 — Permission (slight restructure)

- Keep "Find my books" as primary CTA
- Keep "Choose a folder instead" as secondary
- Add "Customize more →" link that toggles Track B (shows theme/typography steps)
- "Skip for now" jumps to import

**Changes:**
- Move permission logic into `services/permission_service.dart` (testable in isolation)
- Track which path the user chose (quick vs customize) for analytics

#### Step 2 — Format Selection (unchanged)

- Toggle chips for each format, same visual language
- "Skip for now" if none selected

**Changes:**
- Extract `_formatSelection` into `widgets/onboarding/format_selector.dart`
- Persist selection temporarily so returning users see their prior choices

#### Step 3 — Theme Preferences (Track B only)

- Same Light/Dark/OLED cards
- Extract into `widgets/onboarding/theme_picker.dart`

#### Step 3b — Typography Picker (Track B only, new)

- Let user preview reading typeface (Literata, Bitter, PT Serif, Atkinson Hyperlegible)
- Render a sample paragraph in each font
- Selection seeds `ReaderSettings.bodyFontFamily`

#### Step 4 — Import / Scan

- Same scan logic, same progress bar
- On empty result: show a more helpful empty state with a large illustration,
  "Your burrow is empty", and a prominent "Add a book" CTA that opens file picker
- On success: show a mini carousel of discovered book covers as a "preview"
  of what's waiting in the library

**Changes:**
- Extract `_ScanStatusBar` and `_importBody` into `widgets/onboarding/scan_results.dart`
- Add a "Browse sample books" link for users who have no books on device
  (links to a curated set of free EPUBs or a web page)

#### Step 5 — Completion (new)

- Celebratory screen: "Your burrow is ready"
- Show a small summary: "N books found · Theme: Dark · Formats: EPUB, PDF"
- CTA: "Start reading" → LibraryScreen
- Optional: "Tour the app" → triggers a 3-bubble tooltip walkthrough
  of the library screen

---

## Architecture Changes

### File structure

```
lib/
  screens/
    onboarding_screen.dart          # Shell: PageView + navigation + CTA bar (~250 lines)
  widgets/
    onboarding/
      welcome_page.dart             # Step 0
      permission_page.dart          # Step 1
      format_picker.dart            # Step 2
      theme_picker.dart             # Step 3 (Track B)
      typography_picker.dart        # Step 3b (Track B)
      scan_results_page.dart        # Step 4
      completion_page.dart          # Step 5
      onboarding_stage.dart         # Morphing stage container (shared)
      squishy_button.dart           # _Squishy widget (shared)
  services/
    onboarding_flow_controller.dart # Flow state machine: page order, track selection, progress
```

### Flow controller

```dart
class OnboardingFlowController extends ChangeNotifier {
  enum Track { quickStart, personalize }

  final LibraryService _library;
  Track _track = Track.quickStart;
  int _currentStep = 0;
  List<int> _pageOrder = [0, 1, 2, 4]; // quick start default

  // Methods:
  // - selectTrack(Track) — rebuilds pageOrder
  // - next() / back() — navigate with bounds checking
  // - skipToEnd() — jump to import page
  // - complete() — persist onboardingComplete, emit analytics event
  // - List<int> get visiblePages — for the dot indicator
}
```

### Integration with main.dart

```dart
Widget _buildHome() {
  if (_library.onboardingComplete) return const LibraryScreen();
  return OnboardingScreen(
    library: _library,
    controller: OnboardingFlowController(_library),
    onDone: _finishOnboarding,
  );
}
```

### Settings integration

Add an "Onboarding" entry in `SettingsScreen` that re-launches the flow.
This lets users revisit theme/format choices without digging through preferences.

---

## Implementation Phases

### Phase 1: Extract & Refactor (no behavior change)

**Goal:** Break the monolith into testable sub-widgets without changing UX.

- [ ] Create `widgets/onboarding/` directory
- [ ] Extract `OnboardingStage` (morphing container) into its own file
- [ ] Extract `_Squishy` into `widgets/onboarding/squishy_button.dart`
- [ ] Extract welcome page content into `welcome_page.dart`
- [ ] Extract permission page into `permission_page.dart`
- [ ] Extract format picker into `format_picker.dart`
- [ ] Extract theme picker into `theme_picker.dart`
- [ ] Extract scan results into `scan_results_page.dart`
- [ ] Create `OnboardingFlowController` with current 5-page flow
- [ ] Rewrite `OnboardingScreen` as a thin shell (~200 lines) using the controller
- [ ] Run existing tests — all must pass unchanged
- [ ] Commit: "refactor: extract onboarding into sub-widgets + flow controller"

### Phase 2: Polish Welcome & Permission

**Goal:** Better first impression, smoother permission experience.

- [ ] Add subtle entrance animation to den graphic (scale 0.9→1, fade in)
- [ ] Improve permission denied state: show illustration + "Here's how to fix it"
    with device-specific settings deep link
- [ ] Add "Customize more" toggle on permission page (stub for Track B)
- [ ] Add analytics events: `onboarding_started`, `permission_granted`, `permission_denied`
- [ ] Commit: "feat: polish welcome + permission pages"

### Phase 3: Import Page UX

**Goal:** Make the import step feel rewarding, not empty.

- [ ] Design empty state: illustration + "Your burrow is empty" + prominent CTA
- [ ] On scan success: show mini carousel of discovered book covers
- [ ] Add "Browse free books" link for users with no local content
- [ ] Add progress animation (confetti or book-cover rain) on successful import
- [ ] Analytics: `onboarding_scan_started`, `onboarding_scan_completed`, `books_imported_count`
- [ ] Commit: "feat: improved import page with book preview carousel"

### Phase 4: Track B — Personalize Flow

**Goal:** Let users who want more control customize their reading experience.

- [ ] Implement `OnboardingFlowController` track switching
- [ ] Build typography picker widget (font preview cards)
- [ ] Add typography step to Track B page order
- [ ] Persist typography selection to `ReaderSettings`
- [ ] Add "Customize more" toggle UI on permission page
- [ ] Analytics: `onboarding_track_selected`, `theme_selected`, `typography_selected`
- [ ] Commit: "feat: personalize track with typography picker"

### Phase 5: Completion & Settings Integration

**Goal:** Celebrate setup, make preferences revisitable.

- [ ] Build completion page with summary and "Start reading" CTA
- [ ] Add optional app tour (3-tooltip walkthrough of library screen)
- [ ] Add "Onboarding" entry in `SettingsScreen`
- [ ] Add `markOnboardingComplete` to emit final analytics event
- [ ] Commit: "feat: completion page + settings integration"

### Phase 6: Testing & Hardening

**Goal:** Ship-ready quality.

- [ ] Write unit tests for `OnboardingFlowController` (track switching, page order, bounds)
- [ ] Write widget tests for each extracted sub-widget
- [ ] Update existing `onboarding_test.dart` to work with new architecture
- [ ] Accessibility audit: all touch targets ≥ 48dp, contrast ≥ 4.5:1,
      screen reader labels on all interactive elements
- [ ] Performance: ensure no unnecessary rebuilds during page transitions
- [ ] Run `flutter analyze` — zero warnings
- [ ] Commit: "test: comprehensive onboarding test suite"

---

## Analytics Events

| Event | Trigger | Properties |
|-------|---------|------------|
| `onboarding_started` | First page shown | `track: quick_start \| personalize` |
| `onboarding_page_viewed` | Page changed | `page_index`, `page_name` |
| `onboarding_skipped` | Skip tapped | `from_page` |
| `permission_granted` | Storage access granted | — |
| `permission_denied` | Storage access denied | — |
| `format_selected` | Format chip toggled | `format`, `selected` |
| `theme_selected` | Theme card tapped | `theme: light \| dark \| oled` |
| `typography_selected` | Font card tapped | `font_family` |
| `onboarding_scan_started` | Scan begins | `scan_type: device \| folder` |
| `onboarding_scan_completed` | Scan finishes | `books_found`, `books_imported`, `duration_ms` |
| `onboarding_completed` | "Start reading" tapped | `total_duration_ms`, `track` |

---

## Accessibility Requirements

- All interactive elements ≥ 48dp touch target
- WCAG 2.1 AA contrast (4.5:1 normal text, 3:1 large text)
- Screen reader announcements for page transitions
- `Semantics(label:)` on all icons and decorative graphics
- Format/theme/font selection state exposed via `Semantics(selected:)`
- Reduced motion: respect `MediaQuery.disableAnimations` — skip morphing stage,
  use simple cross-fades instead

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Breaking existing tests during refactor | High | Medium | Phase 1 ends with "all tests pass" gate before any behavior changes |
| Track B increases drop-off | Medium | Medium | Track B is opt-in; A/B test with analytics before making default |
| Typography picker bloats onboarding | Low | Low | Font preview cards are simple; max 4 fonts shown |
| Scan still slow on large devices | Medium | Low | Already deferred to final page; add "Background scan" option in Phase 3 |
| Settings re-entry creates confusion | Low | Low | Re-entry launches fresh flow; existing prefs are pre-selected |

---

## Success Criteria

After shipping all phases:

1. **Onboarding completion rate** ≥ 85% (measured by `onboarding_completed` events)
2. **Time to first book** median < 30s
3. **Code maintainability** — `onboarding_screen.dart` ≤ 250 lines (shell only)
4. **Test coverage** — every sub-widget and the flow controller have dedicated tests
5. **Accessibility** — TalkBack walkthrough passes with zero critical issues
6. **Zero regressions** — existing onboarding tests still pass (updated for new architecture)

---

*This document is a living plan. Update status markers as work progresses.*

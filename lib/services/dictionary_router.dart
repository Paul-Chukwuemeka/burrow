import 'dart:async';

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../screens/settings_screen.dart';
import '../widgets/dictionary_picker_sheet.dart';
import '../widgets/dictionary_sheet.dart';
import 'dictionary_service.dart';
import 'external_dictionary_service.dart';
import 'library_service.dart';

/// Decides, per Define action, where a word lookup resolves: the built-in
/// offline dictionary or an external dictionary app.
///
/// Lookup mode ([word] != null): an "always" default goes straight to its
/// dictionary; otherwise the picker shows on every tap. Management mode
/// ([word] == null, reached from Settings): always the picker, nothing
/// launches.
abstract final class DictionaryRouter {
  static Future<void> resolve(
    BuildContext context, {
    required LibraryService library,
    required ReaderTheme theme,
    String? word,
  }) async {
    final def = library.settings.defaultDictionary;
    if (word != null && def != null) {
      if (def == ExternalDictionaryService.burrowChoice) {
        openLocal(context, library: library, theme: theme, word: word);
        return;
      }
      if (await ExternalDictionaryService.launch(def, word)) return;
      // The pinned app is gone or refused: no dead end — revert to ask mode
      // and let this tap resolve through the picker.
      library.settings.defaultDictionary = null;
      await library.saveSettings();
    }

    final apps = await ExternalDictionaryService.listApps();
    if (!context.mounted) return;
    if (word != null && apps.isEmpty) {
      openLocal(context, library: library, theme: theme, word: word);
      return;
    }

    // Awaited so callers (Settings) can refresh after the user closes the
    // sheet; the toolbar calls resolve() unawaited.
    await DictionaryPickerSheet.show(
      context,
      word: word,
      theme: theme,
      apps: apps,
      onSetDefault: (v) {
        library.settings.defaultDictionary = v;
        unawaited(library.saveSettings());
      },
      onUse: (app, isBurrow) {
        if (isBurrow) {
          openLocal(context, library: library, theme: theme, word: word!);
        } else {
          unawaited(ExternalDictionaryService.launch(app.packageName, word!));
        }
      },
    );
  }

  /// Opens the built-in dictionary sheet, or the ~60 MB download dialog when
  /// the dictionary is not downloaded yet.
  static void openLocal(
    BuildContext context, {
    required LibraryService library,
    required ReaderTheme theme,
    String word = '',
  }) {
    if (DictionaryService.instance.isDownloaded) {
      DictionarySheet.show(context, word: word.toLowerCase(), theme: theme);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.background,
        title: Text('Download dictionary?', style: TextStyle(color: theme.text)),
        content: Text(
          'The offline dictionary (~60 MB) is needed to look up word '
          'definitions.\n\nDownload now?',
          style: TextStyle(color: theme.muted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: theme.muted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              SettingsScreen.show(
                context,
                library: library,
                autoDownloadDictionary: true,
              );
            },
            child: Text('Download', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/reader_settings.dart';
import '../screens/settings_screen.dart';
import '../services/dictionary_service.dart';
import '../services/library_service.dart';
import '../widgets/dictionary_sheet.dart';
import '../widgets/selection_toolbar.dart';

/// Floating toolbar shown for a word or text selection.
///
/// Define is only relevant for a single word; Copy and Share operate on the
/// full [text] passed to [show].
class SelectionToolbarOverlay {
  SelectionToolbarOverlay({
    required BuildContext context,
    required this.theme,
    required this.library,
  }) : _context = context;

  final BuildContext _context;
  final ReaderTheme theme;
  final LibraryService library;

  OverlayEntry? _toolbarEntry;
  String _text = '';

  void show(
    Offset globalPosition, {
    required bool singleWord,
    required String word,
    required String text,
  }) {
    dismiss();
    _text = text;

    _toolbarEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: dismiss,
              ),
            ),
            Positioned(
              left: (globalPosition.dx - 140).clamp(
                8.0,
                math.max(8.0, MediaQuery.sizeOf(context).width - 296.0),
              ),
              top: (globalPosition.dy - 56).clamp(
                0.0,
                MediaQuery.sizeOf(context).height - 60,
              ),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: SelectionToolbar(
                    singleWord: singleWord,
                    theme: theme,
                    onDefine: () {
                      dismiss();
                      openDictionarySheet(word);
                    },
                    onCopy: () {
                      dismiss();
                      Clipboard.setData(ClipboardData(text: _text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Copied "$_text"'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    onShare: () {
                      dismiss();
                      SharePlus.instance.share(ShareParams(text: _text));
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!_context.mounted) return;
    Overlay.of(_context).insert(_toolbarEntry!);
  }

  void dismiss() {
    try {
      _toolbarEntry?.remove();
    } catch (e) {
      debugPrint('Failed to remove selection toolbar overlay: $e');
    }
    _toolbarEntry = null;
  }

  void openDictionarySheet(String word) {
    if (!_context.mounted) return;
    if (DictionaryService.instance.isDownloaded) {
      DictionarySheet.show(_context, word: word.toLowerCase(), theme: theme);
    } else {
      showDownloadDialog(word);
    }
  }

  void showDownloadDialog(String word) {
    if (!_context.mounted) return;
    showDialog(
      context: _context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.background,
        title: Text(
          'Download dictionary?',
          style: TextStyle(color: theme.text),
        ),
        content: Text(
          'The offline dictionary (~40 MB) is needed to look up word definitions.\n\nDownload now?',
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
                _context,
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

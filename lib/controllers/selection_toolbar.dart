import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/reader_settings.dart';
import '../screens/settings_screen.dart';
import '../services/dictionary_router.dart';
import '../services/library_service.dart';
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
    this.modalBarrier = true,
  }) : _context = context;

  final BuildContext _context;
  final ReaderTheme theme;
  final LibraryService library;

  /// Whether to install a full-screen tap barrier under the toolbar.
  ///
  /// The PDF reader has no page-level gesture layer of its own for the
  /// overlay to fall through to, so it keeps the barrier (tap-outside
  /// dismisses). The reflowable reader passes `false`: taps outside the
  /// toolbar must reach `_PageContent`, whose `onTapUp` decides link vs. page
  /// flip vs. centre tap.
  final bool modalBarrier;

  OverlayEntry? _toolbarEntry;
  String _text = '';

  void show(
    Offset globalPosition, {
    required bool singleWord,
    required String word,
    required String text,
  }) {
    _removeEntry();
    _text = text;

    _toolbarEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            if (modalBarrier)
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

    if (!_context.mounted) {
      // The entry was never inserted; forget it so a later dismiss() cannot
      // try to remove an uninserted overlay.
      _toolbarEntry = null;
      return;
    }
    Overlay.of(_context).insert(_toolbarEntry!);
  }

  void _removeEntry() {
    try {
      _toolbarEntry?.remove();
    } catch (e) {
      debugPrint('Failed to remove selection toolbar overlay: $e');
    }
    _toolbarEntry = null;
  }

  void dismiss() {
    _removeEntry();
  }

  void openDictionarySheet(String word) {
    if (!_context.mounted) return;
    unawaited(
      DictionaryRouter.resolve(_context, library: library, theme: theme, word: word),
    );
  }

  void showDownloadDialog(String word) {
    if (!_context.mounted) return;
    DictionaryRouter.openLocal(_context, library: library, theme: theme, word: word);
  }
}

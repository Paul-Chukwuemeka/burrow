import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/reader_settings.dart';
import '../screens/settings_screen.dart';
import '../services/dictionary_service.dart';
import '../services/library_service.dart';
import '../widgets/dictionary_sheet.dart';

class DictionaryOverlay {
  DictionaryOverlay({
    required this.context,
    required this.theme,
    required this.library,
  });

  final BuildContext context;
  final ReaderTheme theme;
  final LibraryService library;

  OverlayEntry? _dictionaryButtonEntry;
  ({int start, int end})? _selectedWordRange;

  ({int start, int end})? get selectedWordRange => _selectedWordRange;

  void showWordToolbar(
    Offset globalPosition,
    String word,
    int bodyStart,
    int bodyEnd,
  ) {
    dismissDictionaryButton();
    _selectedWordRange = (start: bodyStart, end: bodyEnd);

    _dictionaryButtonEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: dismissDictionaryButton,
              ),
            ),
            Positioned(
              left: (globalPosition.dx - 140).clamp(
                8.0,
                MediaQuery.sizeOf(context).width - 296.0,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _toolbarButton(
                        label: 'Define',
                        onTap: () {
                          dismissDictionaryButton();
                          openDictionarySheet(word);
                        },
                      ),
                      _toolbarDivider(),
                      _toolbarButton(
                        label: 'Copy',
                        onTap: () {
                          dismissDictionaryButton();
                          Clipboard.setData(ClipboardData(text: word));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Copied "$word"'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _toolbarDivider(),
                      _toolbarButton(
                        label: 'Share',
                        onTap: () {
                          dismissDictionaryButton();
                          SharePlus.instance.share(ShareParams(text: word));
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_dictionaryButtonEntry!);
  }

  Widget _toolbarButton({required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: theme.text,
          ),
        ),
      ),
    );
  }

  Widget _toolbarDivider() {
    return Container(
      width: 1,
      height: 20,
      color: theme.muted.withValues(alpha: 0.3),
    );
  }

  void dismissDictionaryButton() {
    _dictionaryButtonEntry?.remove();
    _dictionaryButtonEntry = null;
    _selectedWordRange = null;
  }

  void openDictionarySheet(String word) {
    if (DictionaryService.instance.isDownloaded) {
      DictionarySheet.show(context, word: word.toLowerCase(), theme: theme);
    } else {
      showDownloadDialog(word);
    }
  }

  void showDownloadDialog(String word) {
    showDialog(
      context: context,
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

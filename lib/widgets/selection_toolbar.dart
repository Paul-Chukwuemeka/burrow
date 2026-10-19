import 'package:flutter/material.dart';

import '../models/reader_settings.dart';

/// The action row shown in the word/selection toolbar.
///
/// [singleWord] controls whether the dictionary action is offered: Define only
/// makes sense for a single word, so multi-word selections show Copy and Share.
class SelectionToolbar extends StatelessWidget {
  const SelectionToolbar({
    super.key,
    required this.singleWord,
    required this.onDefine,
    required this.onCopy,
    required this.onShare,
    required this.theme,
  });

  final bool singleWord;
  final VoidCallback onDefine;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final ReaderTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (singleWord) ...[
          _toolbarButton(label: 'Define', onTap: onDefine),
          _toolbarDivider(),
        ],
        _toolbarButton(label: 'Copy', onTap: onCopy),
        _toolbarDivider(),
        _toolbarButton(label: 'Share', onTap: onShare),
      ],
    );
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
}

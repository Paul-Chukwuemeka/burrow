import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../models/highlight_palette.dart';
import '../models/reader_settings.dart';

/// Bottom sheet of actions for an existing highlight, opened by tapping the
/// painted highlight while reading.
///
/// [onOpenNote] is only shown when the highlight carries a note. Every action
/// closes the sheet before running, so dialogs and snackbars land on the
/// reader.
Future<void> showHighlightActions(
  BuildContext context, {
  required db.HighlightRow row,
  required ReaderTheme theme,
  required VoidCallback onOpenNote,
  required VoidCallback onEditNote,
  required VoidCallback onChangeColor,
  required VoidCallback onDelete,
}) {
  final hasNote = row.note.trim().isNotEmpty;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.background,
    builder: (sheetContext) {
      void run(VoidCallback action) {
        Navigator.of(sheetContext).pop();
        action();
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                row.quote,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.text,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            if (hasNote)
              ListTile(
                leading: Icon(Icons.sticky_note_2_outlined, color: theme.text),
                title: Text('Open note', style: TextStyle(color: theme.text)),
                onTap: () => run(onOpenNote),
              ),
            ListTile(
              leading: Icon(Icons.edit_note, color: theme.text),
              title: Text('Edit note', style: TextStyle(color: theme.text)),
              onTap: () => run(onEditNote),
            ),
            ListTile(
              leading: Icon(Icons.palette_outlined, color: theme.text),
              title: Text('Change colour', style: TextStyle(color: theme.text)),
              onTap: () => run(onChangeColor),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: theme.accent),
              title: Text(
                'Delete highlight',
                style: TextStyle(color: theme.accent),
              ),
              onTap: () => run(onDelete),
            ),
          ],
        ),
      );
    },
  );
}

/// Swatch picker for [kHighlightColors]; resolves to the chosen index.
Future<int?> showHighlightColorPicker(
  BuildContext context, {
  required int current,
  required ReaderTheme theme,
}) {
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('Highlight colour'),
      children: [
        for (var i = 0; i < kHighlightColorCount; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, i),
            child: Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: kHighlightColors[i],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(kHighlightColorNames[i])),
                if (current == i) const Icon(Icons.check, size: 18),
              ],
            ),
          ),
      ],
    ),
  );
}

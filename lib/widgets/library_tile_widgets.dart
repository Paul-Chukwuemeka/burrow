import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../services/library_service.dart';
import 'book_card.dart';

class AuthorTile extends StatelessWidget {
  const AuthorTile({
    required this.name,
    required this.bookCount,
    required this.onTap,
  });

  final String name;
  final int bookCount;
  final VoidCallback onTap;

  Color _avatarColor(ColorScheme scheme) {
    final h = name.hashCode;
    final hue = (h % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: _avatarColor(scheme),
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
        ),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$bookCount book${bookCount == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}

class CollectionTile extends StatefulWidget {
  const CollectionTile({
    required this.collection,
    required this.library,
    required this.onTap,
    required this.onLongPress,
  });

  final db.Collection collection;
  final LibraryService library;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<CollectionTile> createState() => CollectionTileState();
}

class CollectionTileState extends State<CollectionTile> {
  int? _count;

  @override
  void initState() {
    super.initState();
    _loadCount();
  }

  Future<void> _loadCount() async {
    final count = await widget.library.getCollectionBookCount(widget.collection.id);
    if (!mounted) return;
    setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.collections_bookmark_outlined,
              color: scheme.onSecondaryContainer),
        ),
        title: Text(
          widget.collection.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _count != null && _count! > 0
            ? Text(
                '$_count book${_count == 1 ? '' : 's'}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            : null,
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
      ),
    );
  }
}

class SmartGroupTile extends StatelessWidget {
  const SmartGroupTile({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: scheme.tertiaryContainer,
          child: Icon(icon, color: scheme.onTertiaryContainer),
        ),
        title: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$count book${count == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}

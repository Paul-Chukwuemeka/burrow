import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../theme/burrow_tokens.dart';

class SheetAction extends StatelessWidget {
  const SheetAction({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.iconBg,
    required this.onTap,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color iconBg;
  final Color? labelColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeMd)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 21, color: iconColor),
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color:
                        labelColor ?? Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({
    required this.label,
    required this.value,
    this.isFile = false,
  });

  final String label;
  final String value;
  final bool isFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface,
              ),
              overflow: isFile ? TextOverflow.ellipsis : null,
              maxLines: isFile ? 2 : null,
            ),
          ),
        ],
      ),
    );
  }
}

class CollectionPickerTile extends StatefulWidget {
  const CollectionPickerTile({
    required this.collection,
    required this.isInCollection,
    required this.onToggle,
  });

  final db.Collection collection;
  final Future<bool> isInCollection;
  final VoidCallback onToggle;

  @override
  State<CollectionPickerTile> createState() => CollectionPickerTileState();
}

class CollectionPickerTileState extends State<CollectionPickerTile> {
  late final Future<bool> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.isInCollection;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<bool>(
      future: _future,
      builder: (context, snapshot) {
        final inCollection = snapshot.data ?? false;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: Icon(
            inCollection ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: inCollection ? scheme.primary : scheme.outlineVariant,
          ),
          title: Text(
            widget.collection.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          onTap: widget.onToggle,
        );
      },
    );
  }
}

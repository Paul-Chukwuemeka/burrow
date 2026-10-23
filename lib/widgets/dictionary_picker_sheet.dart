import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../services/external_dictionary_service.dart';

/// Bottom sheet listing the dictionary apps a Define action can resolve
/// through: the built-in offline dictionary plus every external app installed
/// on the device that handles word definitions.
///
/// Lookup ([word] != null): tapping a row resolves this one word now, pinning
/// a row ("Always") makes that choice the stored default. Management
/// ([word] == null, reached from Settings): tapping simply sets the default;
/// nothing launches.
abstract final class DictionaryPickerSheet {
  static Future<void> show(
    BuildContext context, {
    String? word,
    required List<ExternalDictionaryApp> apps,
    required void Function(String? defaultDictionary) onSetDefault,
    required void Function(ExternalDictionaryApp app, bool isBurrow) onUse,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PickerContent(
        word: word,
        apps: apps,
        onSetDefault: onSetDefault,
        onUse: onUse,
      ),
    );
  }
}

/// A row's dictionary identity: either Burrow's built-in choice or an
/// external app's package name. Null means "ask every time".
class _PickerContent extends StatelessWidget {
  const _PickerContent({
    required this.word,
    required this.apps,
    required this.onSetDefault,
    required this.onUse,
  });

  final String? word;
  final List<ExternalDictionaryApp> apps;
  final void Function(String?) onSetDefault;
  final void Function(ExternalDictionaryApp app, bool isBurrow) onUse;

  bool get _managementMode => word == null;

  @override
  Widget build(BuildContext context) {
    final outer = Theme.of(context);
    final scheme = outer.colorScheme;
    return Material(
      color: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _managementMode ? 'Default dictionary' : 'Define with',
                style: outer.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_managementMode)
                _row(
                  context,
                  icon: Icons.help_outline,
                  title: 'Ask every time',
                  subtitle: 'Show this picker on every Define',
                  choice: null,
                  primaryAction: onSetDefault,
                  pin: null,
                ),
              _row(
                context,
                icon: Icons.menu_book,
                title: 'Define with Burrow',
                subtitle: _managementMode ? null : 'Built-in offline dictionary',
                choice: ExternalDictionaryService.burrowChoice,
                primaryAction: _managementMode
                    ? onSetDefault
                    : (c) => _useBurrow(),
                pin: _managementMode ? null : onSetDefault,
              ),
              for (final app in apps)
                _row(
                  context,
                  icon: Icons.translate,
                  title: app.label,
                  subtitle: _managementMode ? app.packageName : null,
                  choice: app.packageName,
                  primaryAction: _managementMode
                      ? onSetDefault
                      : (c) => onUse(app, false),
                  pin: _managementMode ? null : onSetDefault,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required String? choice,
    required void Function(String?) primaryAction,
    void Function(String?)? pin,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isBurrow =
        choice == ExternalDictionaryService.burrowChoice && choice != null;
    return ListTile(
      leading: Icon(
        icon,
        color: isBurrow ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
      onTap: () {
        Navigator.of(context).pop();
        primaryAction(choice);
      },
      trailing: pin == null
          ? null
          : IconButton(
              icon: const Icon(Icons.push_pin_outlined),
              tooltip: 'Always',
              onPressed: () {
                Navigator.of(context).pop();
                pin(choice);
              },
            ),
    );
  }

  void _useBurrow() {
    onUse(
      const ExternalDictionaryApp(
        packageName: ExternalDictionaryService.burrowChoice,
        label: 'Burrow',
      ),
      true,
    );
  }
}

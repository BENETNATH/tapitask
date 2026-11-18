import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";

/// Dialogues liste (rename / delete / couleur) partagés entre home et
/// list — triplé recopié à l'identique sur les deux écrans (spec lot T, T8).

Future<String?> renameListDialog(BuildContext context, LocalList list) {
  final controller = TextEditingController(text: list.title);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.renameList),
      content: TextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(S.rename)),
      ],
    ),
  );
}

Future<bool> deleteListDialog(BuildContext context, LocalList list) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text("Supprimer « ${list.title} » ?"),
      content: Text(S.deleteListBody),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel)),
        FilledButton.tonalIcon(
            icon: const Icon(Icons.delete_outline),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.errorContainer),
            onPressed: () => Navigator.pop(context, true),
            label: Text(S.delete)),
      ],
    ),
  );
  return confirmed == true;
}

/// Palette + parsing couleur unifiés (variant home, robuste : tryParse).
Future<String?> pickListColorDialog(BuildContext context) {
  const palette = [
    null,
    "#00897B", "#43A047", "#1E88E5", "#5E35B1", "#D32F2F",
    "#F4511E", "#F6BF26", "#6D4C41", "#546E7A", "#37474F",
  ];
  return showDialog<String?>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(S.listColor),
      content: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final hex in palette)
            InkWell(
              onTap: () => Navigator.pop(context, hex),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: hex == null ? null : _parseColor(hex),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outline),
                  shape: BoxShape.circle,
                ),
                child: hex == null
                    ? const Icon(Icons.format_color_reset, size: 20)
                    : null,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(S.close)),
      ],
    ),
  );
}

Color? _parseColor(String? hex) {
  if (hex == null) return null;
  final v = int.tryParse(hex.replaceFirst("#", "0xFF"));
  return v == null ? null : Color(v);
}

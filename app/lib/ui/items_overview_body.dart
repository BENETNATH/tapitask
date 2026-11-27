import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../state/app_state.dart";
import "task_details.dart";

/// Corps partagé de TodayScreen/TodoAllScreen : StreamBuilder → état vide
/// → liste de Card/TaskTile. [subtitleText] construit le SUFFIXE affiché
/// après le titre de la liste (today : juste le suffixe retard ;
/// todo_all : échéance + suffixe retard).
class ItemsOverviewBody extends StatelessWidget {
  final Stream<List<LocalItem>> stream;
  final AppState state;
  final String emptyText;
  final String Function(LocalItem item, bool overdue) subtitleText;
  const ItemsOverviewBody({
    super.key,
    required this.stream,
    required this.state,
    required this.emptyText,
    required this.subtitleText,
  });

  Future<LocalList?> _listOf(String id) => state.db.getList(id);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<LocalItem>>(
      stream: stream,
      initialData: const [],
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.celebration_outlined,
                    size: 64, color: scheme.outline),
                const SizedBox(height: 12),
                Text(emptyText, style: TextStyle(color: scheme.outline)),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final overdue = item.overdueAt(DateTime.now());
            return Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(vertical: 3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: overdue
                        ? scheme.errorContainer
                        : scheme.outlineVariant),
              ),
              child: TaskTile(
                state: state,
                item: item,
                title: Text(item.label),
                subtitle: FutureBuilder<LocalList?>(
                  future: _listOf(item.listId),
                  builder: (context, snap) => Text(
                    "${snap.data?.title ?? ""}${subtitleText(item, overdue)}",
                    style: TextStyle(
                        fontSize: 12,
                        color: overdue ? scheme.error : scheme.outline),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

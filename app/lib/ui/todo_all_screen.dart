import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "due_format.dart";
import "task_details.dart";

/// Vue « À faire » : tous les items non cochés, toutes listes confondues
/// (uniquement les listes synchronisées), groupés par liste.
class TodoAllScreen extends StatefulWidget {
  final AppState state;
  const TodoAllScreen({super.key, required this.state});

  @override
  State<TodoAllScreen> createState() => _TodoAllScreenState();
}

class _TodoAllScreenState extends State<TodoAllScreen> {
  late final Stream<List<LocalItem>> _todoStream;

  @override
  void initState() {
    super.initState();
    // 3.1 (prod3) : le flux watch() est créé une seule fois — recréé à
    // chaque build, il faisait flasher l'état vide.
    _todoStream = widget.state.db.watchAllUncheckedItems();
    widget.state.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    widget.state.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(S.todoAll,
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<List<LocalItem>>(
        stream: _todoStream,
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
                  Text(S.allDone,
                      style: TextStyle(color: scheme.outline)),
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
              final due = item.localDue;
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
                  state: widget.state,
                  item: item,
                  title: Text(item.label),
                  subtitle: FutureBuilder<LocalList?>(
                    future: _listOf(item.listId),
                    builder: (context, snap) => Text(
                      "${snap.data?.title ?? ""}"
                      "${due != null ? "  •  ${dueLabel(due, withTime: false)}" : ""}"
                      "${overdue ? S.t("overdueSuffix") : ""}",
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
      ),
    );
  }

  Future<LocalList?> _listOf(String id) => widget.state.db.getList(id);
}

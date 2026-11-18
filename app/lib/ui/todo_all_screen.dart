import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "due_format.dart";

/// Vue « À faire » : tous les items non cochés, toutes listes confondues
/// (uniquement les listes synchronisées), groupés par liste.
class TodoAllScreen extends StatefulWidget {
  final AppState state;
  const TodoAllScreen({super.key, required this.state});

  @override
  State<TodoAllScreen> createState() => _TodoAllScreenState();
}

class _TodoAllScreenState extends State<TodoAllScreen> {
  @override
  void initState() {
    super.initState();
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
        stream: widget.state.db.watchAllUncheckedItems(),
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
                  Text("Tout est fait !",
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
              final overdue =
                  item.dueDate != null && item.dueDate!.isBefore(DateTime.now());
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
                child: CheckboxListTile(
                  value: item.done,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(item.label),
                  subtitle: FutureBuilder<LocalList?>(
                    future: _listOf(item.listId),
                    builder: (context, snap) => Text(
                      "${snap.data?.title ?? ""}"
                      "${item.dueDate != null ? "  •  ${_fmtDue(item.dueDate!)}" : ""}"
                      "${overdue ? "  •  en retard" : ""}",
                      style: TextStyle(
                          fontSize: 12,
                          color: overdue ? scheme.error : scheme.outline),
                    ),
                  ),
                  onChanged: (v) =>
                      widget.state.toggleItem(item.id, v ?? false),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _fmtDue(DateTime d) => dueLabel(d.toLocal(), withTime: false);

  Future<LocalList?> _listOf(String id) => widget.state.db.getList(id);
}

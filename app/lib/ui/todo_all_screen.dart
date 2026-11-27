import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "due_format.dart";
import "items_overview_body.dart";

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
    return Scaffold(
      appBar: AppBar(
        title: Text(S.todoAll,
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: ItemsOverviewBody(
        stream: _todoStream,
        state: widget.state,
        emptyText: S.allDone,
        subtitleText: (item, overdue) {
          final due = item.localDue;
          return "${due != null ? "  •  ${dueLabel(due, withTime: false)}" : ""}"
              "${overdue ? S.t("overdueSuffix") : ""}";
        },
      ),
    );
  }
}

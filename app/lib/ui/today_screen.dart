import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "task_details.dart";

/// Vue « Aujourd'hui » : tous les items dus aujourd'hui ou en retard,
/// toutes listes confondues (uniquement les listes synchronisées).
class TodayScreen extends StatefulWidget {
  final AppState state;
  const TodayScreen({super.key, required this.state});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
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
    
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            () => widget.state.undoLast(),
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text("Aujourd'hui",
            style: TextStyle(
                color: scheme.onSurface, fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<List<LocalItem>>(
        stream: widget.state.db.watchDueItems(),
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
                  Text(S.nothingToday,
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
                      "${overdue ? "  •  en retard" : ""}",
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
    ),
    );
  }

  Future<LocalList?> _listOf(String id) => widget.state.db.getList(id);
}

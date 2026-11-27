import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../data/database.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "items_overview_body.dart";

/// Vue « Aujourd'hui » : tous les items dus aujourd'hui ou en retard,
/// toutes listes confondues (uniquement les listes synchronisées).
class TodayScreen extends StatefulWidget {
  final AppState state;
  const TodayScreen({super.key, required this.state});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late final Stream<List<LocalItem>> _dueStream;

  @override
  void initState() {
    super.initState();
    // 3.1 (prod3) : le flux watch() est créé une seule fois — recréé à
    // chaque build, il faisait flasher l'état vide.
    _dueStream = widget.state.db.watchDueItems();
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
        title: Text(S.today,
            style: TextStyle(
                color: scheme.onSurface, fontWeight: FontWeight.w600)),
      ),
      body: ItemsOverviewBody(
        stream: _dueStream,
        state: widget.state,
        emptyText: S.nothingToday,
        subtitleText: (item, overdue) => overdue ? S.t("overdueSuffix") : "",
      ),
    ),
    );
  }
}

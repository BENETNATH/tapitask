import "dart:async";

import "package:flutter/foundation.dart";
import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../data/database.dart";
import "../platform/file_service.dart";
import "../state/app_state.dart";
import "due_format.dart";
import "google_tasks_dialog.dart";
import "list_dialogs.dart";
import "due_picker.dart";
import "share_screen.dart";
import "task_details.dart";
import "../l10n/s.dart";

class ListScreen extends StatefulWidget {
  final AppState state;
  final String listId;

  /// Deep-link quick-add : focaliser le champ d'ajout au montage.
  final bool focusAdd;
  const ListScreen(
      {super.key,
      required this.state,
      required this.listId,
      this.focusAdd = false});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  final _quickAdd = TextEditingController();
  final _addFocus = FocusNode();
  String _recurrence = "none";

  /// Échéance choisie pour le prochain ajout (puce « Échéance » de la zone
  /// d'ajout). Null = aucune (les mots-clés « demain »… restent actifs).
  DueChoice? _newDue;
  bool? _showCompleted;
  bool get _hideCompleted => _showCompleted == null
      ? widget.state.settings["hide_done_app"] == true
      : !_showCompleted!;
  String? _parentIdForNextAdd;

  /// Switch de liste en place (lot Q / Q2) : même État, `setState` —
  /// pas de `pushReplacementNamed` (un État neuf flashait un titre
  /// « Liste » + l'état vide au 1er frame). Les caches gardent les
  /// dernières données affichées pendant le rechargement.
  String _listId = "";
  List<LocalList> _lists = const [];
  List<LocalItem> _items = const [];
  StreamSubscription? _itemsSub;

  void _loadLists() {
    widget.state.db.visibleLists().then((l) {
      if (!mounted) return;
      setState(() => _lists = l);
    });
  }

  void _loadItems() {
    _itemsSub?.cancel();
    _itemsSub = widget.state.db.watchItemsOf(_listId).listen((items) {
      if (!mounted) return;
      setState(() => _items = items);
    });
  }

  @override
  void initState() {
    super.initState();
    _listId = widget.listId;
    _loadLists();
    _loadItems();
    widget.state.addListener(_onChanged);
    if (widget.focusAdd) {
      // Différé ~400 ms : après un cold-start, la fenêtre a demandé
      // SOFT_INPUT_STATE_VISIBLE à l'onResume sans cible de saisie ; un
      // requestFocus trop tôt (au montage/post-frame) a son show IME avalé,
      // le clavier ne s'ouvre qu'au prochain tap.
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        _addFocus.requestFocus();
      });
    }
  }

  void _onChanged() {
    setState(() {});
    _loadLists();
  }

  /// Switch directly to another list without going back to the home screen.
  void _switchList(String listId) {
    if (listId == _listId) return;
    _listId = listId;
    _loadItems();
    setState(() {});
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    widget.state.removeListener(_onChanged);
    _addFocus.dispose();
    _quickAdd.dispose(); // 3.2 (prod3) : jamais disposé.
    super.dispose();
  }

  Future<void> _renameList(LocalList list) async {
    final title = await renameListDialog(context, list);
    if (title != null && title.trim().isNotEmpty) {
      await widget.state.renameList(list.id, title.trim());
    }
  }

  Future<void> _pickColor(LocalList list) async {
    final choice = await pickListColorDialog(context);
    if (choice != list.color) {
      await widget.state.setListColor(list.id, choice);
    }
  }

  Future<void> _deleteList(LocalList list) async {
    if (await deleteListDialog(context, list)) {
      await widget.state.deleteList(list.id);
      if (mounted) Navigator.pop(context);
    }
  }

  /// D-7 (spec 2026-11-25) : export de la liste courante (JSON / Markdown /
  /// CSV) — le corps serveur est sauvé tel quel sous `« titre ».format`.
  Future<void> _exportList(LocalList list, String action) async {
    final fmt =
        action == "export_json" ? "json" : action == "export_md" ? "md" : "csv";
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await runExport(
          widget.state.api, "/lists/${list.id}/export.$fmt",
          "${_fileSlug(list.title)}.$fmt");
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text(S.exportedOk)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(S.exportFailed)));
    }
  }

  /// D-7 : import (JSON ou markdown) — POST /import, le serveur crée des
  /// nouvelles listes ; l'annulation du dialog ne montre rien.
  Future<void> _importFile() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await runImport(widget.state.api);
      if (count != null) {
        messenger.showSnackBar(SnackBar(content: Text(S.importedOk)));
      }
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(S.importFailed)));
    }
  }

  String _fileSlug(String title) {
    final slug =
        title.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "-");
    return slug.isEmpty ? "list" : slug;
  }

  /// Titre de l'app bar, construit sur le cache `_lists` : sur un État
  /// neuf, l'ancien FutureBuilder flashait « Liste » au 1er frame (lot Q).
  Widget _title(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = _lists.indexWhere((l) => l.id == _listId);
    final list = index >= 0 ? _lists[index] : null;
    // C2.3 : couleur invalide (ex. "#zz") → fallback, pas de crash
    // (comme home_screen, via parseColor/int.tryParse).
    final titleStyle = TextStyle(
        color: parseColor(list?.color) ?? scheme.onSurface,
        fontWeight: FontWeight.w600);
    // Le sélecteur ◀ ▾ ▶ n'apparaît qu'à partir de 2 listes actives.
    if (_lists.length < 2) {
      return Text(list?.title ?? "Liste",
          maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle);
    }
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        IconButton(
          tooltip: S.prevList,
          icon: const Icon(Icons.chevron_left, size: 22),
          onPressed: index > 0 ? () => _switchList(_lists[index - 1].id) : null,
        ),
        Expanded(
          child: PopupMenuButton<String>(
            tooltip: S.switchList,
            initialValue: _listId,
            onSelected: _switchList,
            itemBuilder: (context) => [
              for (final l in _lists)
                PopupMenuItem(
                  value: l.id,
                  child: Row(children: [
                    if (l.id == _listId)
                      const Icon(Icons.check, size: 16)
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Flexible(
                        child: Text(l.title, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            child: Text(
              "${list?.title ?? "Liste"} ▾",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
        ),
        IconButton(
          tooltip: S.nextList,
          icon: const Icon(Icons.chevron_right, size: 22),
          onPressed: index >= 0 && index < _lists.length - 1
              ? () => _switchList(_lists[index + 1].id)
              : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            widget.state.undoLast(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: _title(context),
          actions: [
            PopupMenuButton<String>(
              onSelected: _onListMenuAction,
              itemBuilder: (context) => _buildListMenuItems(),
            ),
          ],
        ),
        body: Column(
          children: [
            Card(
              elevation: 0,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Column(
                  children: [
                    TextField(
                      controller: _quickAdd,
                      focusNode: _addFocus,
                      autofocus:
                          defaultTargetPlatform == TargetPlatform.windows,
                      maxLines: 3,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: _parentIdForNextAdd != null
                            ? S.subtaskHint
                            : "Ajouter… (collez plusieurs lignes = plusieurs items)",
                        suffixIcon: IconButton(
                          icon: Icon(Icons.add_circle, color: scheme.primary),
                          onPressed: _submit,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          if (_parentIdForNextAdd != null)
                            ActionChip(
                              label: Text(S.subtask),
                              avatar: const Icon(Icons.subdirectory_arrow_right,
                                  size: 18),
                              onPressed: () =>
                                  setState(() => _parentIdForNextAdd = null),
                            ),
                          // Expanded + Align : la puce prend sa taille naturelle
                          // et ne se tronque que si la place manque.
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: InputChip(
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                avatar: Icon(
                                    _newDue == null
                                        ? Icons.event_outlined
                                        : Icons.event,
                                    size: 18,
                                    color: _newDue == null
                                        ? scheme.outline
                                        : scheme.primary),
                                label: Text(
                                  _newDue == null
                                      ? S.dueDate
                                      : dueLabel(_newDue!.date!,
                                          withTime: true,
                                          allDay: _newDue!.allDay),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                tooltip: S.setDueDate,
                                onPressed: _pickNewDue,
                                onDeleted: _newDue == null
                                    ? null
                                    : () => setState(() => _newDue = null),
                              ),
                            ),
                          ),
                          // Flexible + isExpanded : le libellé se tronque au
                          // lieu de déborder (petits écrans, grande police).
                          Flexible(
                            child: DropdownButton<String>(
                              value: _recurrence,
                              underline: const SizedBox.shrink(),
                              isDense: true,
                              isExpanded: true,
                              alignment: AlignmentDirectional.centerEnd,
                              items: [
                                for (final r in const [
                                  "none",
                                  "daily",
                                  "weekly",
                                  "monthly",
                                ])
                                  DropdownMenuItem(
                                    value: r,
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: Text(
                                      switch (r) {
                                        "daily" => S.daily,
                                        "weekly" => S.weekly,
                                        "monthly" => S.monthly,
                                        _ => S.noRepeat,
                                      },
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _recurrence = v ?? "none"),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: _itemsBody()),
          ],
        ),
      ),
    );
  }

  Future<void> _onListMenuAction(String action) async {
    final state = widget.state;
    if (action == "googleTasks") {
      await _sendOpenTasksToGoogle();
      return;
    }
    if (action == "googleImport") {
      final listId = _listId;
      await showGoogleTasksImportDialog(
          context,
          (source, tasks) =>
              state.importGoogleTasks(listId, source, tasks));
      return;
    }
    if (action == "completed") {
      setState(() => _showCompleted = _hideCompleted);
      return;
    }
    // clean / share : déplaçés des anciens IconButtons pour libérer
    // la zone du titre (spec lot P, P2b) — logique déplacée, pas dupliquée.
    if (action == "clean") {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(S.cleanDoneConfirm),
          content: Text(S.cleanDoneBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(S.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(S.clean)),
          ],
        ),
      );
      if (confirmed == true) await state.purgeDone(_listId);
    }
    if (action == "share") {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ShareScreen(state: state, listId: _listId),
        ),
      );
    }
    final list = await _list();
    if (!mounted) return; // S3 (prod4) : plus d'UI après l'await
    if (list == null) return;
    if (action == "rename") await _renameList(list);
    if (action == "delete") await _deleteList(list);
    if (action == "sync") {
      await widget.state.setListLocalOnly(list.id, !list.localOnly);
    }
    if (action == "color") await _pickColor(list);
    if (action == "default") {
      await widget.state.setDefaultList(
          widget.state.defaultListId == list.id ? null : list.id);
    }
    // D-7 (spec 2026-11-25) : export par liste (JSON/Markdown/CSV)
    if (action == "export_json" ||
        action == "export_md" ||
        action == "export_csv") {
      await _exportList(list, action);
    }
    if (action == "import") await _importFile();
  }

  List<PopupMenuEntry<String>> _buildListMenuItems() {
    return [
      PopupMenuItem(
        value: "completed",
        child: Row(children: [
          Icon(_hideCompleted
              ? Icons.visibility
              : Icons.visibility_off),
          const SizedBox(width: 12),
          Flexible(
              child: Text(_hideCompleted
                  ? S.showCompletedTasks
                  : S.hideCompletedTasks)),
        ]),
      ),
      PopupMenuItem(
        value: "default",
        child: Row(children: [
          Icon(widget.state.defaultListId == _listId
              ? Icons.star
              : Icons.star_border),
          const SizedBox(width: 12),
          Flexible(
            child: Text(widget.state.defaultListId == _listId
                ? S.unsetDefaultList
                : S.setDefaultList),
          ),
        ]),
      ),
      PopupMenuItem(
        value: "clean",
        child: Row(children: [
          Icon(Icons.delete_sweep_outlined),
          const SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.cleanDone, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "share",
        child: Row(children: [
          Icon(Icons.share),
          const SizedBox(width: 12),
          Flexible(
              child: Text(S.share, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      if (canSendToGoogleTasks)
        PopupMenuItem(
          value: "googleTasks",
          child: Row(children: [
            const Icon(Icons.outbox_outlined),
            const SizedBox(width: 12),
            Flexible(child: Text(S.sendOpenToGoogleTasks)),
          ]),
        ),
      if (canSendToGoogleTasks &&
          _lists.any(
              (list) => list.id == _listId && list.role != "viewer"))
        PopupMenuItem(
          value: "googleImport",
          child: Row(children: [
            const Icon(Icons.download_outlined),
            const SizedBox(width: 12),
            Flexible(child: Text(S.importGoogleTasks)),
          ]),
        ),
      PopupMenuItem(
        value: "color",
        child: Row(children: [
          Icon(Icons.palette_outlined),
          SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.color, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "export_json",
        child: Row(children: [
          Icon(Icons.file_download_outlined),
          const SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.exportJson, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "export_md",
        child: Row(children: [
          Icon(Icons.description_outlined),
          const SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.exportMarkdown,
                      overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "export_csv",
        child: Row(children: [
          Icon(Icons.table_chart_outlined),
          const SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.exportCsv, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "import",
        child: Row(children: [
          Icon(Icons.upload_file_outlined),
          const SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.importFile, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "sync",
        child: FutureBuilder<LocalList?>(
          future: _list(),
          builder: (context, snap) => Row(children: [
            Icon(snap.data?.localOnly == true
                ? Icons.cloud_off_outlined
                : Icons.cloud_done_outlined),
            const SizedBox(width: 12),
            Flexible(
                child: Text(snap.data?.localOnly == true
                    ? "Activer la synchro"
                    : "Local uniquement",
                    overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
      PopupMenuItem(
        value: "rename",
        child: Row(children: [
          Icon(Icons.drive_file_rename_outline),
          SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.rename, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      PopupMenuItem(
        value: "delete",
        child: Row(children: [
          Icon(Icons.delete_outline),
          SizedBox(width: 12),
          Flexible(
              child:
                  Text(S.delete, overflow: TextOverflow.ellipsis)),
        ]),
      ),
    ];
  }

  /// Corps de la liste, construit sur le cache `_items` : l'ancien
  /// StreamBuilder flashait l'état vide au 1er frame d'un État neuf (lot Q).
  Widget _itemsBody() {
    final scheme = Theme.of(context).colorScheme;
    final itemsById = {for (final item in _items) item.id: item};
    final active = <LocalItem>[];
    final completed = <LocalItem>[];
    final children = <String, List<LocalItem>>{};
    for (final item in _items) {
      final parent = itemsById[item.parentId];
      if (parent != null && parent.parentId == null && parent.done == item.done) {
        children.putIfAbsent(parent.id, () => []).add(item);
      } else if (item.done) {
        if (!_hideCompleted) completed.add(item);
      } else {
        active.add(item);
      }
    }
    if (active.isEmpty && completed.isEmpty) {
      return Center(
        child: Text(S.nothingToDoAdd, style: TextStyle(color: scheme.outline)),
      );
    }
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS =>
        true,
      _ => false,
    };
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          sliver: SliverReorderableList(
            itemCount: active.length,
            itemBuilder: (context, index) {
              final item = active[index];
              final row = _itemRow(item, children[item.id] ?? [],
                  dragIndex: desktop ? index : null);
              return desktop
                  ? KeyedSubtree(key: ValueKey(item.id), child: row)
                  : ReorderableDelayedDragStartListener(
                      key: ValueKey(item.id), index: index, child: row);
            },
            onReorderItem: (oldIndex, newIndex) async {
              final reordered = [...active];
              reordered.insert(newIndex, reordered.removeAt(oldIndex));
              await widget.state.reorderOpenItems(reordered);
            },
          ),
        ),
        if (completed.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(S.completedTasks,
                  style: Theme.of(context).textTheme.labelLarge),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverList.builder(
              itemCount: completed.length,
              itemBuilder: (context, index) {
                final item = completed[index];
                return _itemRow(item, children[item.id] ?? []);
              },
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _itemRow(LocalItem item, List<LocalItem> children, {int? dragIndex}) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final due = item.localDue;
    return Dismissible(
      key: ValueKey(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      onDismissed: (_) async {
        final messenger = ScaffoldMessenger.of(context);
        final undo = await state.deleteItem(item.id);
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(
          content: Text("« ${item.label} » supprimé"),
          action: SnackBarAction(label: S.undo, onPressed: () => undo()),
          duration: const Duration(seconds: 5),
        ));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TaskTile(
            state: state,
            item: item,
            dense: true,
            title: _itemTitle(item),
            subtitle: _itemSubtitle(item),
            onLongPress: () => _itemActions(item),
            trailing: state.visibleActions || dragIndex != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.visibleActions) ...[
                        IconButton(
                          tooltip: due == null ? S.setDueDate : S.editDueDate,
                          icon: Icon(
                              due == null ? Icons.event_outlined : Icons.event,
                              size: 20,
                              color: due == null
                                  ? scheme.outline
                                  : scheme.primary),
                          onPressed: () => _pickDueDate(item),
                        ),
                        IconButton(
                          tooltip: S.itemActions,
                          icon: Icon(Icons.more_vert,
                              size: 20, color: scheme.outline),
                          onPressed: () => _itemActions(item),
                        ),
                      ],
                      if (dragIndex != null)
                        ReorderableDragStartListener(
                          index: dragIndex,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                    ],
                  )
                : null,
          ),
          for (final child in children)
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 2),
              child: TaskTile(
                state: state,
                item: child,
                onLongPress: () => _itemActions(child),
                dense: true,
                title: _itemTitle(child, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _itemTitle(LocalItem item, {double? fontSize}) => Text(item.label,
      style: TextStyle(
        fontSize: fontSize,
        color:
            item.done ? Theme.of(context).colorScheme.onSurfaceVariant : null,
        decoration: item.done ? TextDecoration.lineThrough : null,
      ));

  Future<void> _itemActions(LocalItem item) async {
    final due = item.localDue;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          if (item.parentId == null)
            ListTile(
              leading: const Icon(Icons.subdirectory_arrow_right),
              title: Text(S.addSubtask),
              onTap: () => Navigator.pop(context, "subtask"),
            ),
          ListTile(
            leading: Icon(Icons.event,
                color:
                    due != null ? Theme.of(context).colorScheme.primary : null),
            title: Text(due == null
                ? S.setDueDate
                : "${S.dueDate} · ${dueLabel(due, withTime: true, allDay: item.dueDay != null)}"),
            onTap: () => Navigator.pop(context, "due"),
          ),
          ListTile(
            leading: Icon(Icons.notes_outlined,
                color: item.notes != null
                    ? Theme.of(context).colorScheme.primary
                    : null),
            title: Text(S.note),
            onTap: () => Navigator.pop(context, "notes"),
          ),
          if (canSendToGoogleTasks)
            ListTile(
              leading: const Icon(Icons.outbox_outlined),
              title: Text(S.sendToGoogleTasks),
              onTap: () => Navigator.pop(context, "googleTasks"),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case "subtask":
        setState(() => _parentIdForNextAdd = item.id);
        break;
      case "due":
        await _pickDueDate(item);
        break;
      case "notes":
        await showTaskDetails(context, widget.state, item);
        break;
      case "googleTasks":
        await showGoogleTasksDialog(context, [item]);
        break;
    }
  }

  Future<void> _sendOpenTasksToGoogle() async {
    final listId = _listId;
    final tasks = await widget.state.db.uncheckedItemsOf(listId);
    if (!mounted || _listId != listId) return;
    if (tasks.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.nothingToDo)));
      return;
    }
    await showGoogleTasksDialog(context, tasks);
  }

  /// Échéance ergonomique : raccourcis en un tap, puis sélecteur
  /// date/heure complet si besoin. Aussi accessible via l'icône
  /// calendrier sur chaque item (pas besoin d'un appui long).
  Future<void> _pickDueDate(LocalItem item) async {
    final choice = await chooseDueDate(context, item.label, item.localDue,
        allDay: item.dueDay != null);
    if (choice == null || !mounted) return;
    if (choice.date == null) {
      await widget.state.setItemDetails(item.id, clearDue: true);
    } else {
      await widget.state
          .setItemDetails(item.id, dueDate: choice.date, dueDay: choice.day);
    }
  }

  /// Échéance de la tâche en cours de saisie (zone d'ajout).
  Future<void> _pickNewDue() async {
    final title = _quickAdd.text.trim().split("\n").first;
    final choice = await chooseDueDate(
        context, title.isEmpty ? S.dueDate : title, _newDue?.date,
        allDay: _newDue?.allDay ?? true);
    if (choice == null || !mounted) return;
    setState(() => _newDue = choice.date == null ? null : choice);
  }

  Future<LocalList?> _list() => widget.state.db.getList(_listId);

  Widget _subtitlePart(IconData icon, String text, {Color? color}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color))),
      ]);

  Widget? _itemSubtitle(LocalItem item) {
    final parts = <Widget>[];
    if (item.localDue case final due?) {
      final overdue = item.overdueAt(DateTime.now());
      parts.add(_subtitlePart(
          overdue ? Icons.warning_amber_rounded : Icons.event,
          dueLabel(due, withTime: true, allDay: item.dueDay != null),
          color: overdue ? Theme.of(context).colorScheme.error : null));
    }
    if (item.recurrence != "none") {
      parts.add(_subtitlePart(Icons.replay, _recurrenceLabel(item.recurrence)));
    }
    if (item.notes != null && item.notes!.isNotEmpty) {
      parts.add(_subtitlePart(Icons.notes_outlined, item.notes!));
    }
    if (parts.length == 1) return parts.first;
    if (parts.isEmpty) return null;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: parts);
  }

  // 3.5 (prod3) : clés i18n existantes (S.daily/weekly/monthly).
  String _recurrenceLabel(String r) => switch (r) {
        "daily" => S.daily,
        "weekly" => S.weekly,
        "monthly" => S.monthly,
        _ => "",
      };

  void _submit() async {
    final text = _quickAdd.text;
    if (text.trim().isEmpty) return;
    _quickAdd.clear();
    await widget.state.addQuickItems(
      _listId,
      text,
      parentId: _parentIdForNextAdd,
      recurrence: _recurrence,
      dueDate: _newDue?.date,
      dueDay: _newDue?.day,
    );
    setState(() {
      _parentIdForNextAdd = null;
      _newDue = null;
    });
  }
}

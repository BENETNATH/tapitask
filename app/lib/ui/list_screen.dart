import "dart:async";

import "package:flutter/foundation.dart";
import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../data/database.dart";
import "../state/app_state.dart";
import "due_format.dart";
import "list_dialogs.dart";
import "due_picker.dart";
import "share_screen.dart";
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
  DateTime? _newDue;
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

  /// Titre de l'app bar, construit sur le cache `_lists` : sur un État
  /// neuf, l'ancien FutureBuilder flashait « Liste » au 1er frame (lot Q).
  Widget _title(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = _lists.indexWhere((l) => l.id == _listId);
    final list = index >= 0 ? _lists[index] : null;
    final titleStyle = TextStyle(
        color: list?.color == null
            ? scheme.onSurface
            : Color(int.parse(list!.color!.replaceFirst("#", "0xFF"))),
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
    final state = widget.state;
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
              onSelected: (action) async {
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
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ShareScreen(state: state, listId: _listId),
                    ),
                  );
                }
                final list = await _list();
                if (list == null) return;
                if (action == "rename") await _renameList(list);
                if (action == "delete") await _deleteList(list);
                if (action == "sync") {
                  await widget.state.setListLocalOnly(list.id, !list.localOnly);
                }
                if (action == "color") await _pickColor(list);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: "clean",
                  child: Row(children: [
                    Icon(Icons.delete_sweep_outlined),
                    const SizedBox(width: 12),
                    Text(S.cleanDone),
                  ]),
                ),
                PopupMenuItem(
                  value: "share",
                  child: Row(children: [
                    Icon(Icons.share),
                    const SizedBox(width: 12),
                    Text(S.share),
                  ]),
                ),
                PopupMenuItem(
                  value: "color",
                  child: Row(children: [
                    Icon(Icons.palette_outlined),
                    SizedBox(width: 12),
                    Text(S.color),
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
                      Text(snap.data?.localOnly == true
                          ? "Activer la synchro"
                          : "Local uniquement"),
                    ]),
                  ),
                ),
                PopupMenuItem(
                  value: "rename",
                  child: Row(children: [
                    Icon(Icons.drive_file_rename_outline),
                    SizedBox(width: 12),
                    Text(S.rename),
                  ]),
                ),
                PopupMenuItem(
                  value: "delete",
                  child: Row(children: [
                    Icon(Icons.delete_outline),
                    SizedBox(width: 12),
                    Text(S.delete),
                  ]),
                ),
              ],
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
                                      : _dueLabel(_newDue!),
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

  /// Corps de la liste, construit sur le cache `_items` : l'ancien
  /// StreamBuilder flashait l'état vide au 1er frame d'un État neuf (lot Q).
  Widget _itemsBody() {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final items = _items;
    // W2 : le réglage de l'app est hide_done_app (hide_done pilote seul le
    // volet/widget).
    final hideDone = widget.state.settings["hide_done_app"] as bool? ?? true;
    final top = items
        .where((i) => i.parentId == null && (!hideDone || !i.done))
        .toList();
    if (top.isEmpty) {
      return Center(
        child: Text(S.nothingToDoAdd, style: TextStyle(color: scheme.outline)),
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: true,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      itemCount: top.length,
      onReorderItem: (oldIndex, newIndex) async {
        // onReorderItem fournit déjà le newIndex ajusté au retrait
        // de l'élément déplacé (plus de décrément manuel).
        final moved = top.removeAt(oldIndex);
        top.insert(newIndex, moved);
        // hide_done_app ON : liste visible ≠ ordre absolu — réécrire les
        // positions absolues en ordre stable : les items masqués (cochés)
        // gardent leur slot, les visibles se répartissent dans les slots
        // restants, dans le nouvel ordre visible.
        final all = items.where((i) => i.parentId == null).toList();
        var k = 0;
        for (var pos = 0; pos < all.length; pos++) {
          await state.reorderItem(
              hideDone && all[pos].done ? all[pos].id : top[k++].id, pos);
        }
      },
      itemBuilder: (context, i) {
        final item = top[i];
        final children = items.where((c) => c.parentId == item.id).toList();
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
            {
              messenger.showSnackBar(
                SnackBar(
                  content: Text("« ${item.label} » supprimé"),
                  action: SnackBarAction(
                    label: "ANNULER",
                    onPressed: () => undo(),
                  ),
                  duration: const Duration(seconds: 5),
                ),
              );
            }
          },
          child: Column(
            key: ValueKey("col-${item.id}"),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onLongPress: () => _itemActions(item),
                child: CheckboxListTile(
                  dense: true,
                  value: item.done,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    item.label,
                    style: TextStyle(
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      color: item.done ? scheme.outline : null,
                    ),
                  ),
                  subtitle: _itemSubtitle(item),
                  secondary: state.visibleActions
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: item.dueDate == null
                                  ? S.setDueDate
                                  : S.editDueDate,
                              icon: Icon(
                                item.dueDate == null
                                    ? Icons.event_outlined
                                    : Icons.event,
                                size: 20,
                                color: item.dueDate == null
                                    ? scheme.outline
                                    : scheme.primary,
                              ),
                              onPressed: () => _pickDueDate(item),
                            ),
                            IconButton(
                              tooltip: S.itemActions,
                              icon: Icon(Icons.more_vert,
                                  size: 20, color: scheme.outline),
                              onPressed: () => _itemActions(item),
                            ),
                          ],
                        )
                      : null,
                  onChanged: (v) => state.toggleItem(item.id, v ?? false),
                ),
              ),
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(left: 32, bottom: 2),
                  child: CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: child.done,
                    title: Text(child.label,
                        style: TextStyle(
                            fontSize: 13,
                            color: child.done ? scheme.outline : null)),
                    onChanged: (v) => state.toggleItem(child.id, v ?? false),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _itemActions(LocalItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.subdirectory_arrow_right),
            title: Text(S.addSubtask),
            onTap: () => Navigator.pop(context, "subtask"),
          ),
          ListTile(
            leading: Icon(Icons.event,
                color: item.dueDate != null
                    ? Theme.of(context).colorScheme.primary
                    : null),
            title: Text(item.dueDate == null
                ? S.setDueDate
                : "${S.dueDate} : ${_dueLabel(item.dueDate!)}"),
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
        ]),
      ),
    );
    switch (action) {
      case "subtask":
        setState(() => _parentIdForNextAdd = item.id);
        break;
      case "due":
        await _pickDueDate(item);
        break;
      case "notes":
        await _editNotes(item);
        break;
    }
  }

  /// Échéance ergonomique : raccourcis en un tap, puis sélecteur
  /// date/heure complet si besoin. Aussi accessible via l'icône
  /// calendrier sur chaque item (pas besoin d'un appui long).
  Future<void> _pickDueDate(LocalItem item) async {
    final choice = await chooseDueDate(context, item.label, item.dueDate);
    if (choice == null || !mounted) return;
    if (choice.date == null) {
      await widget.state.setItemDetails(item.id, clearDue: true);
    } else {
      await widget.state.setItemDetails(item.id, dueDate: choice.date);
    }
  }

  /// Échéance de la tâche en cours de saisie (zone d'ajout).
  Future<void> _pickNewDue() async {
    final title = _quickAdd.text.trim().split("\n").first;
    final choice = await chooseDueDate(
        context, title.isEmpty ? S.dueDate : title, _newDue);
    if (choice == null || !mounted) return;
    setState(() => _newDue = choice.date);
  }

  Future<void> _editNotes(LocalItem item) async {
    final controller = TextEditingController(text: item.notes ?? "");
    final notes = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.note),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(S.ok)),
        ],
      ),
    );
    if (notes != null) {
      await widget.state.setItemDetails(item.id, notes: notes);
    }
  }

  String _dueLabel(DateTime d) => dueLabel(d, withTime: true);

  Future<LocalList?> _list() => widget.state.db.getList(_listId);

  Widget _subtitlePart(IconData icon, String text, {Color? color}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: color)),
      ]);

  Widget? _itemSubtitle(LocalItem item) {
    final parts = <Widget>[];
    if (item.dueDate != null) {
      final overdue = item.dueDate!.isBefore(DateTime.now());
      parts.add(_subtitlePart(
          overdue ? Icons.warning_amber_rounded : Icons.event,
          _dueLabel(item.dueDate!),
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

  String _recurrenceLabel(String r) => switch (r) {
        "daily" => "quotidien",
        "weekly" => "hebdomadaire",
        "monthly" => "mensuel",
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
      dueDate: _newDue,
    );
    setState(() {
      _parentIdForNextAdd = null;
      _newDue = null;
    });
  }
}

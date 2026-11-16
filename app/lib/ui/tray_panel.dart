import "package:desktop_multi_window/desktop_multi_window.dart";
import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../data/database.dart";
import "../state/app_state.dart";

/// The tray flyout (volet rapide): tiny, instant, offline-first.
/// - Pinned lists as chips at the top (tap to switch)
/// - Items of the selected list
/// - Quick-add bar pinned at the BOTTOM
/// - Pin toggle ("toujours visible") + compact open/close actions.
class TrayPanel extends StatefulWidget {
  final AppState state;
  final int windowId;
  const TrayPanel({super.key, required this.state, required this.windowId});

  @override
  State<TrayPanel> createState() => _TrayPanelState();
}

class _TrayPanelState extends State<TrayPanel> {
  final _quickAdd = TextEditingController();
  String? _activeList;
  bool _pinned = false;

  static const _prefPinned = "flyout_pinned";

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onChanged);
    _loadPinned();
  }

  Future<void> _loadPinned() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _pinned = prefs.getBool(_prefPinned) ?? false);
    }
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    widget.state.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _togglePin() async {
    final prefs = await SharedPreferences.getInstance();
    final value = !_pinned;
    await prefs.setBool(_prefPinned, value);
    // Tell the main window so the tray click honours the pin.
    await DesktopMultiWindow.invokeMethod(0, "flyoutPin", value);
    setState(() => _pinned = value);
  }

  Future<void> _close() async {
    await DesktopMultiWindow.invokeMethod(0, "flyoutClosed");
    await DesktopMultiWindow.invokeMethod(0, "hideFlyout");
  }

  Future<void> _openApp() async {
    await DesktopMultiWindow.invokeMethod(0, "showMainWindow");
  }

  Future<void> _submit() async {
    final text = _quickAdd.text;
    if (_activeList == null || text.trim().isEmpty) return;
    _quickAdd.clear();
    await widget.state.addQuickItems(_activeList!, text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          // --- header: pin + open app + close ---
          Container(
            height: 36,
            color: scheme.surfaceContainerHighest,
            child: Row(children: [
              const SizedBox(width: 4),
              IconButton(
                tooltip: _pinned
                    ? "Toujours visible (épinglé)"
                    : "Épingler : toujours visible",
                icon: Icon(
                    _pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 18,
                    color: _pinned ? scheme.primary : scheme.outline),
                onPressed: _togglePin,
              ),
              const Spacer(),
              IconButton(
                tooltip: "Ouvrir l'application",
                icon: Icon(Icons.open_in_new, size: 18,
                    color: scheme.outline),
                onPressed: _openApp,
              ),
              IconButton(
                tooltip: "Fermer le volet",
                icon: Icon(Icons.close, size: 18, color: scheme.outline),
                onPressed: _close,
              ),
              const SizedBox(width: 4),
            ]),
          ),
          // --- pinned lists as chips ---
          FutureBuilder<List<LocalList>>(
            future: widget.state.db.pinnedLists(),
            builder: (context, snapshot) {
              final lists = snapshot.data ?? [];
              if (lists.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    "Épinglez des listes dans l'application pour les voir ici.",
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                );
              }
              if (_activeList == null ||
                  !lists.any((l) => l.id == _activeList)) {
                _activeList = lists.first.id;
              }
              return SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final list in lists)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(list.title,
                              style: const TextStyle(fontSize: 12)),
                          selected: _activeList == list.id,
                          onSelected: (_) =>
                              setState(() => _activeList = list.id),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          // --- items of the selected list ---
          Expanded(
            child: FutureBuilder<List<LocalItem>>(
              future: _activeList == null
                  ? Future.value(<LocalItem>[])
                  : widget.state.db.itemsOf(_activeList!),
              builder: (context, snapshot) {
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return Center(
                    child: Text("Rien à faire",
                        style: TextStyle(color: scheme.outline, fontSize: 12)),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return CheckboxListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: item.done,
                      title: Text(item.label,
                          style: TextStyle(
                              fontSize: 13,
                              decoration: item.done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: item.done ? scheme.outline : null)),
                      onChanged: (v) =>
                          widget.state.toggleItem(item.id, v ?? false),
                    );
                  },
                );
              },
            ),
          ),
          // --- quick-add at the bottom ---
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: TextField(
              controller: _quickAdd,
              autofocus: false,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: "Ajouter… (multi-lignes = multi-items)",
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(Icons.add_circle, color: scheme.primary),
                  onPressed: _submit,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
      ),
    );
  }
}

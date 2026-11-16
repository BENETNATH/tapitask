import "package:material_ui/material_ui.dart";
import "package:flutter/services.dart";

import "../state/app_state.dart";
import "../l10n/s.dart";

/// Recherche globale (Ctrl+K côté bureau) sur tous les items de toutes les listes.
class SearchScreen extends StatefulWidget {
  final AppState state;
  const SearchScreen({super.key, required this.state});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<dynamic>? _results;
  Map<String, String> _listTitles = {};
  // Debounce: one DB query per typing pause, not one per keystroke.
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_debouncedSearch);
    _loadLists();
  }

  Future<void> _loadLists() async {
    final lists = await widget.state.db.visibleLists();
    setState(() {
      _listTitles = {for (final l in lists) l.id.toString(): l.title};
    });
  }

  void _debouncedSearch() {
    final generation = ++_searchGeneration;
    Future.delayed(const Duration(milliseconds: 200), () async {
      if (generation != _searchGeneration || !mounted) return;
      await _search();
    });
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.length < 2) {
      setState(() => _results = null);
      return;
    }
    final items = await widget.state.db.search(q);
    if (mounted) setState(() => _results = items);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            () => widget.state.undoLast(),
      },
      child: Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
              hintText: S.searchHint),
        ),
      ),
      body: _results == null
          ? Center(child: Text(S.searchMinChars))
          : _results!.isEmpty
              ? Center(child: Text(S.noResult))
              : ListView.builder(
                  itemCount: _results!.length,
                  itemBuilder: (context, i) {
                    final item = _results![i];
                    final listName =
                        _listTitles[item.listId] ?? "";
                    return CheckboxListTile(
                      value: item.done,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(item.label),
                      subtitle: Text(listName,
                          style: const TextStyle(fontSize: 12)),
                      onChanged: (v) async {
                        await widget.state.toggleItem(item.id, v ?? false);
                        _search();
                      },
                    );
                  },
                ),
    ),
    );
  }
}

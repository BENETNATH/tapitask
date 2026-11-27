import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:http/http.dart" as http;
import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../data/google_tasks_api.dart";
import "../l10n/s.dart";

bool get canSendToGoogleTasks =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> showGoogleTasksDialog(
    BuildContext context, List<LocalItem> tasks) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoogleTasksDialog(tasks: tasks),
  );
}

Future<void> showGoogleTasksImportDialog(BuildContext context,
    Future<int> Function(String, List<GoogleTask>) importTasks) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoogleTasksDialog(importTasks: importTasks),
  );
}

class _GoogleTasksDialog extends StatefulWidget {
  const _GoogleTasksDialog({this.tasks = const [], this.importTasks});

  final List<LocalItem> tasks;
  final Future<int> Function(String, List<GoogleTask>)? importTasks;

  @override
  State<_GoogleTasksDialog> createState() => _GoogleTasksDialogState();
}

class _GoogleTasksDialogState extends State<_GoogleTasksDialog> {
  static const _channel = MethodChannel("com.tapitask/tapitask/google_tasks");

  final _client = http.Client();
  GoogleTasksApi? _api;
  List<GoogleTaskList> _destinations = [];
  String? _destinationId;
  bool _loading = true;
  bool _sending = false;
  int _copied = 0;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _loadDestinations();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadDestinations() async {
    try {
      final token = await _channel.invokeMethod<String>("authorize");
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        _outcome = S.googleTasksAccessCancelled;
        return;
      }
      final api = GoogleTasksApi(_client, token);
      final destinations = await api.lists();
      if (!mounted) return;
      _api = api;
      _destinations = destinations;
      if (destinations.isEmpty) _outcome = S.googleTasksNoLists;
    } on PlatformException {
      _outcome = S.googleTasksAccessFailed;
    } on Exception {
      _outcome = S.googleTasksListFailed;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final api = _api;
    final destinationId = _destinationId;
    if (_sending || _outcome != null || api == null || destinationId == null) {
      return;
    }
    setState(() => _sending = true);
    final importTasks = widget.importTasks;
    if (importTasks != null) {
      try {
        final tasks = await api.tasks(destinationId);
        final count = await importTasks(destinationId, tasks);
        _outcome = S.googleTasksImported(count);
      } on Object {
        _outcome = S.googleTasksImportFailed;
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    // Google puts each inserted task first. Work from the bottom to keep the
    // order of the Tapitask list in the group of newly created tasks.
    for (final task in widget.tasks.reversed) {
      try {
        await api.createTask(destinationId, task);
      } on GoogleTasksRequestFailed catch (e) {
        _outcome = e.writeUncertain
            ? S.googleTasksWriteUncertain(task.label)
            : S.googleTasksWriteFailed(task.label);
        break;
      }
      if (!mounted) return;
      setState(() => _copied++);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _outcome ??= S.googleTasksCopied(_copied, widget.tasks.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.tasks.length;
    final importing = widget.importTasks != null;
    final outcome = _outcome;
    final ready = !_loading && !_sending && outcome == null;
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        title: Text(importing ? S.importGoogleTasks : S.sendToGoogleTasks),
        scrollable: true,
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading) Text(S.googleTasksLoading),
              if (_loading) const LinearProgressIndicator(),
              if (ready) ...[
                if (!importing) ...[
                  Text(total == 1
                      ? widget.tasks.single.label
                      : S.googleTasksOpenCount(total)),
                  const SizedBox(height: 12),
                ],
                DropdownButton<String>(
                  isExpanded: true,
                  value: _destinationId,
                  hint: Text(S.googleTasksChooseList,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  items: [
                    for (final destination in _destinations)
                      DropdownMenuItem(
                        value: destination.id,
                        child: Text(destination.title,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _destinationId = value),
                ),
              ],
              if (_sending) ...[
                if (!importing) ...[
                  Text(S.googleTasksCopied(_copied, total)),
                  const SizedBox(height: 8),
                ],
                LinearProgressIndicator(
                    value: importing ? null : _copied / total),
              ],
              if (outcome != null) ...[
                if (_copied > 0 && _copied < total) ...[
                  Text(S.googleTasksCopied(_copied, total)),
                  const SizedBox(height: 8),
                ],
                Text(outcome),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context),
            child: Text(outcome == null ? S.cancel : S.close),
          ),
          if (ready)
            FilledButton(
              onPressed: _destinationId == null ? null : _send,
              child: Text(importing ? S.googleTasksImport : S.googleTasksSend),
            ),
        ],
      ),
    );
  }
}

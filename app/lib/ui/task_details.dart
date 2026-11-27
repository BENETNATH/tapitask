import "package:flutter/services.dart";
import "package:material_ui/material_ui.dart";
import "package:url_launcher/url_launcher.dart";

import "../data/database.dart";
import "../data/task_links.dart";
import "../l10n/s.dart";
import "../state/app_state.dart";
import "due_format.dart";
import "due_picker.dart";

Future<void> showTaskDetails(
    BuildContext context, AppState state, LocalItem item) async {
  final current = await state.db.getItem(item.id);
  if (!context.mounted || current == null) return;
  final edits = await showDialog<({String? notes, DueChoice? due})>(
    context: context,
    builder: (_) => _TaskDetails(current),
  );
  if (edits == null || (edits.notes == null && edits.due == null)) return;
  await state.setItemDetails(item.id,
      notes: edits.notes,
      dueDate: edits.due?.date,
      dueDay: edits.due?.day,
      clearDue: edits.due != null && edits.due!.date == null);
}

class TaskTile extends StatelessWidget {
  const TaskTile(
      {super.key,
      required this.state,
      required this.item,
      required this.title,
      this.subtitle,
      this.trailing,
      this.dense = false,
      this.onLongPress,
      this.onToggled});

  final AppState state;
  final LocalItem item;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool dense;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggled;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: dense,
        leading: Checkbox(
          value: item.done,
          semanticLabel: item.label,
          onChanged: (done) async {
            if (done == null) return;
            await state.toggleItem(item.id, done);
            onToggled?.call();
          },
        ),
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: () => showTaskDetails(context, state, item),
        onLongPress: onLongPress,
      );
}

class _TaskDetails extends StatefulWidget {
  const _TaskDetails(this.item);

  final LocalItem item;

  @override
  State<_TaskDetails> createState() => _TaskDetailsState();
}

class _TaskDetailsState extends State<_TaskDetails> {
  late final _notes = TextEditingController(text: widget.item.notes ?? "");
  DueChoice? _due;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _openLink(Uri link) async {
    try {
      if (await launchUrl(link, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // Present the same message when a platform cannot open the URL.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(S.linkFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final current = _due ??
        DueChoice(widget.item.localDue, allDay: widget.item.dueDay != null);
    final date = current.date;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.item.label),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.item.done ? S.taskCompleted : S.taskOpen),
            TextButton.icon(
              icon: const Icon(Icons.event_outlined),
              label: Text(date == null
                  ? S.setDueDate
                  : dueLabel(date, withTime: true, allDay: current.allDay)),
              onPressed: () async {
                final choice = await chooseDueDate(
                    context, widget.item.label, date,
                    allDay: current.allDay);
                if (choice != null && mounted) setState(() => _due = choice);
              },
            ),
            TextField(
              controller: _notes,
              minLines: 3,
              maxLines: 6,
              decoration:
                  InputDecoration(labelText: S.note, hintText: S.taskNotesHint),
              onChanged: (_) => setState(() {}),
            ),
            for (final link
                in taskLinks("${widget.item.label}\n${_notes.text}"))
              TextButton.icon(
                onPressed: () => _openLink(link),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(link.toString(), overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, (
                  notes: _notes.text == (widget.item.notes ?? "")
                      ? null
                      : _notes.text,
                  due: _due,
                )),
            child: Text(S.saveTaskDetails)),
      ],
    );
  }
}

import "package:material_ui/material_ui.dart";

import "../data/database.dart";
import "../l10n/s.dart";

/// Sélecteur d'échéance partagé (calendrier d'un item, zone d'ajout d'une
/// liste, dialogue « Nouvelle tâche » de l'accueil).

/// Résultat du sélecteur d'échéance : [date] null = échéance retirée.
class DueChoice {
  final DateTime? date;
  final bool allDay;
  const DueChoice(this.date, {this.allDay = true});

  String? get day => allDay && date != null ? calendarDay(date!) : null;
}

/// Raccourcis en un tap puis sélecteur date/heure complet.
/// Retourne null si annulé ; `DueChoice(null)` si l'échéance est retirée.
Future<DueChoice?> chooseDueDate(
    BuildContext context, String title, DateTime? current,
    {bool allDay = true}) async {
  final now = DateTime.now();
  final time =
      current != null && !allDay ? TimeOfDay.fromDateTime(current) : null;
  DueChoice onDay(DateTime day, TimeOfDay? time) => DueChoice(
        DateTime(
            day.year, day.month, day.day, time?.hour ?? 0, time?.minute ?? 0),
        allDay: time == null,
      );
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title:
          Text("${S.dueDate} — $title", style: const TextStyle(fontSize: 16)),
      children: [
        SimpleDialogOption(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.today_outlined),
            title: Text(S.today),
          ),
          onPressed: () => Navigator.pop(context, "today"),
        ),
        SimpleDialogOption(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_outward),
            title: Text(S.tomorrow),
          ),
          onPressed: () => Navigator.pop(context, "tomorrow"),
        ),
        SimpleDialogOption(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.date_range_outlined),
            title: Text(S.inAWeek),
          ),
          onPressed: () => Navigator.pop(context, "week"),
        ),
        SimpleDialogOption(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.calendar_month_outlined),
            title: Text(S.chooseDate),
          ),
          onPressed: () => Navigator.pop(context, "custom"),
        ),
        if (current != null)
          SimpleDialogOption(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.schedule),
              title: Text(allDay ? S.addTime : S.editTime),
            ),
            onPressed: () => Navigator.pop(context, "time"),
          ),
        if (time != null)
          SimpleDialogOption(
            child: ListTile(dense: true, title: Text(S.allDay)),
            onPressed: () => Navigator.pop(context, "allDay"),
          ),
        if (current != null)
          SimpleDialogOption(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.event_busy),
              title: Text(S.removeDueDate),
            ),
            onPressed: () => Navigator.pop(context, "clear"),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  switch (choice) {
    case "today":
      return onDay(now, time);
    case "tomorrow":
      return onDay(DateTime(now.year, now.month, now.day + 1), time);
    case "week":
      return onDay(DateTime(now.year, now.month, now.day + 7), time);
    case "clear":
      return const DueChoice(null);
    case "allDay":
      return onDay(current!, null);
    case "time":
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: time ?? TimeOfDay.fromDateTime(now),
      );
      return pickedTime == null ? null : onDay(current!, pickedTime);
  }
  final initial = current ?? now;
  final first = DateTime(now.year - 1, now.month, now.day);
  final last = DateTime(now.year + 3, now.month, now.day);
  if (!context.mounted) return null;
  final picked = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: initial.isBefore(first) ? initial : first,
    lastDate: initial.isAfter(last) ? initial : last,
    helpText: S.dueDate,
  );
  return picked == null ? null : onDay(picked, time);
}

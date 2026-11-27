import "../l10n/s.dart";

/// Échéance lisible, unique pour les 3 surfaces (spec lot T, T10) :
/// « aujourd'hui [hh:mm] » / « demain [hh:mm] » / « hier (en retard) » /
/// « jj/mm [hh:mm] ». Le suffixe hh:mm n'apparaît que si [withTime] et que
/// l'heure n'est pas 00:00.
String dueLabel(DateTime d, {required bool withTime, bool? allDay}) {
  final now = DateTime.now();
  final today = DateTime.utc(now.year, now.month, now.day);
  final day = DateTime.utc(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final hasTime = withTime && !(allDay ?? (d.hour == 0 && d.minute == 0));
  final hh = d.hour.toString().padLeft(2, "0");
  final mm = d.minute.toString().padLeft(2, "0");
  switch (diff) {
    case 0:
      return hasTime ? "${S.todayLabel} $hh:$mm" : S.todayLabel;
    case 1:
      return hasTime ? "${S.tomorrowLabel} $hh:$mm" : S.tomorrowLabel;
    case -1:
      return hasTime && allDay == false ? "${S.yesterdayOverdue} $hh:$mm" : S.yesterdayOverdue;
    default:
      return hasTime
          ? "${day.day}/${day.month} $hh:$mm"
          : "${day.day}/${day.month}";
  }
}

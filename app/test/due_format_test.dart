import "package:flutter_test/flutter_test.dart";

import "package:tapitask/l10n/s.dart";
import "package:tapitask/ui/due_format.dart";

/// Spec lot T (T10) : unique helper d'échéance — sorties exactes des
/// 3 implémentations actuelles : « aujourd'hui » / « demain » /
/// « hier (en retard) » / « jj/mm », suffixe « hh:mm » si withTime
/// (et l'heure n'est pas 00:00).
void main() {
  test("T10 : dueLabel — aujourd'hui / demain / jj/mm, avec et sans heure", () {
    S.setLocale("fr");
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 9, 30);
    final tomorrow = today.add(const Duration(days: 1));
    final later =
        DateTime(now.year, now.month, now.day, 9, 30).add(const Duration(days: 3));

    expect(dueLabel(today, withTime: false), S.todayLabel);
    expect(dueLabel(tomorrow, withTime: false), S.tomorrowLabel);
    expect(dueLabel(later, withTime: false), "${later.day}/${later.month}");
    expect(dueLabel(today, withTime: true), "${S.todayLabel} 09:30");
    expect(dueLabel(tomorrow, withTime: true), "${S.tomorrowLabel} 09:30");
    expect(dueLabel(later, withTime: true),
        "${later.day}/${later.month} 09:30");

    // heure minuscule : pas de suffixe hh:mm (comportement des 3 impls).
    final midnight = DateTime(now.year, now.month, now.day);
    expect(dueLabel(midnight, withTime: true), S.todayLabel);

    // EN : mêmes branches, labels traduits.
    S.setLocale("en");
    expect(dueLabel(today, withTime: false), S.todayLabel);
    expect(dueLabel(tomorrow, withTime: false), S.tomorrowLabel);
    S.setLocale("fr");
  });
}

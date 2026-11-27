import "package:drift/drift.dart" show DatabaseConnection;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/calendar_screen.dart";

void main() {
  testWidgets("calendar ranges, date selection and status filters on a phone",
      (tester) async {
    S.setLocale("en");
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDb.forTesting(DatabaseConnection(NativeDatabase.memory(),
        closeStreamsSynchronously: true));
    addTearDown(db.close);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thirdDay = DateTime(now.year, now.month, now.day + 3, 15);
    final fifthDay = DateTime(now.year, now.month, now.day + 4, 15);
    await db.upsertList(LocalListsCompanion.insert(
        id: "local", title: "Home", ownerId: "", updatedAt: now));
    await db.addItem("planned", "local", "Today's appointment", 0, now,
        dueDate: today, dueDay: calendarDay(today));
    await db.addItem("completed", "local", "Finished early", 1, now,
        done: true, completedAt: now, dueDate: fifthDay);
    await db.addItem("third", "local", "Fourth day appointment", 2, now,
        dueDate: thirdDay);
    await db.addItem("outside", "local", "Next period appointment", 3, now,
        dueDate: fifthDay);

    await tester
        .pumpWidget(MaterialApp(home: CalendarScreen(state: AppState(db: db))));
    await tester.pumpAndSettle();
    expect(find.text(S.calendarWeek), findsOneWidget);
    expect(find.text("Finished early"), findsOneWidget);
    expect(tester.widget<Text>(find.text("Finished early")).style?.decoration,
        TextDecoration.lineThrough);

    await tester.tap(find.text(S.completedTasks));
    await tester.pumpAndSettle();
    expect(find.text("Finished early"), findsNothing);
    expect(find.text("Today's appointment"), findsOneWidget);
    await tester.tap(find.text(S.completedTasks));
    await tester.tap(find.text(S.calendarPlanned));
    await tester.pumpAndSettle();
    expect(find.text("Today's appointment"), findsNothing);
    expect(find.text("Finished early"), findsOneWidget);
    await tester.tap(find.text(S.calendarPlanned));
    await tester.pumpAndSettle();

    final view = find.byKey(const ValueKey("calendar-view"));
    await tester.tap(view);
    await tester.pumpAndSettle();
    for (final label in [
      S.calendarDay,
      S.calendarDays(2),
      S.calendarDays(3),
      S.calendarDays(4),
      S.calendarMonth
    ]) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    await tester.tap(find.text(S.calendarDays(4)).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text("Fourth day appointment"), findsOneWidget);
    expect(find.text("Next period appointment"), findsNothing);
    await tester.tap(find.byTooltip(S.calendarNext));
    await tester.pumpAndSettle();
    expect(find.text("Next period appointment"), findsOneWidget);
    expect(find.text("Finished early"), findsNothing);

    await tester.tap(view);
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.calendarMonth).hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byTooltip(S.today));
    await tester.pumpAndSettle();
    final local =
        MaterialLocalizations.of(tester.element(find.byType(CalendarScreen)));
    final target = DateTime(today.year, today.month, today.day == 1 ? 2 : 1);
    final date = local.formatFullDate(target);
    final targetCell = find.byWidgetPredicate((widget) =>
        widget is Semantics &&
        widget.properties.label == date &&
        widget.properties.button == true);
    await tester.tap(targetCell);
    await tester.pumpAndSettle();
    expect(tester.widget<Semantics>(targetCell).properties.selected, isTrue);
    expect(find.text(date), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

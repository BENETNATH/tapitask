import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/home_screen.dart";

void main() {
  testWidgets(
      "aperçu inline : le badge d'échéance colle au label (gap constant 8px)",
      (tester) async {
    S.setLocale("fr");
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    await db.upsertList(LocalListsCompanion(
      id: const Value("l1"),
      title: const Value("Maison"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    final now = DateTime.now();
    await db.addItem("i1", "l1", "Payer le loyer", 1, now,
        dueDate: now.add(const Duration(days: 1)));
    // compact_due est ON par défaut → le badge est non nul.
    final badge = state.dueSuffix((await db.uncheckedItemsOf("l1")).single)!;
    expect(badge, isNotEmpty);

    Future<double> gapAt(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(MaterialApp(
          localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
          home: HomeScreen(state: state)));
      await tester.pumpAndSettle();
      final labelRect = tester.getRect(find.text("Payer le loyer"));
      final badgeRect = tester.getRect(find.text(badge));
      return badgeRect.left - labelRect.right;
    }

    final gapNarrow = await gapAt(const Size(400, 600));
    final gapWide = await gapAt(const Size(900, 600));

    // Le badge colle au label quelle que soit la largeur : 8px constants.
    expect(gapWide, gapNarrow);
    expect(gapWide, 8.0);

    await tester.binding.setSurfaceSize(null);
    await db.close();
  });
}

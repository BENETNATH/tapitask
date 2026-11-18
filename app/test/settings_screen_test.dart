import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/settings_screen.dart";

/// Spec lot S (S1) : l'icône d'info des réglages est TAPABLE — un tap simple
/// ouvre le dialogue d'aide (un Tooltip seul ne s'affiche qu'au long-press
/// sur Android ; l'utilisateur s'attend à un tap).
void main() {
  testWidgets("S1 : tap sur l'icône d'info → dialogue d'aide du réglage",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.api = await ApiClient.load();

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: SettingsScreen(state: state)));
    await tester.pumpAndSettle();

    final infoIcons = find.byIcon(Icons.info_outline);
    expect(infoIcons, findsWidgets);

    // 1er réglage avec info = Échéances.
    await tester.tap(infoIcons.first);
    await tester.pumpAndSettle();

    expect(find.text(S.dueDatesHelp), findsOneWidget,
        reason: "S1 : le tap simple sur l'icône d'info doit ouvrir le "
            "dialogue d'aide (avant fix : le tap ne fait rien)");
    await db.close();
  });

  testWidgets("T1 : le switch « Actions visibles » écrit visible_actions",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final state = AppState(db: db);
    state.api = await ApiClient.load();
    state.settings["visible_actions"] = true;

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: SettingsScreen(state: state)));
    await tester.pumpAndSettle();

    final row = find
        .ancestor(of: find.text(S.visibleActions), matching: find.byType(Row))
        .first;
    final sw = find.descendant(of: row, matching: find.byType(Switch)).first;
    expect(tester.widget<Switch>(sw).value, true);
    await tester.tap(sw);
    await tester.pumpAndSettle();

    expect(state.settings["visible_actions"], false,
        reason: "T1 : le toggle doit écrire visible_actions (avant fix : "
            "il écrivait une autre clé — le réglage n'avait aucun effet)");
    await db.close();
  });
}

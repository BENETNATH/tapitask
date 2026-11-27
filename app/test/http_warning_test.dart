// Audit lot T : URL serveur http:// → avertissement à l'enregistrement
// (dialogue) + bannière persistante ; https:// → rien.
import "package:drift/native.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/main.dart" show appShell;
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/login_screen.dart";

void main() {
  testWidgets("T8 : URL http:// → avertissement visible avant login",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("http://cleartext.example.com");
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), "a@b.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "LongPassw0rd!x");
    await tester.tap(find.text(S.login));
    await tester.pumpAndSettle();
    expect(find.text(S.insecureServerBody), findsOneWidget,
        reason: "le dialogue d'avertissement doit être visible");
    // pas de requête envoyée avant confirmation explicite
    expect(state.api.accessToken, isNull);
  });

  testWidgets("T8 : URL https:// → pas d'avertissement", (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://secure.example.com");
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), "a@b.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "LongPassw0rd!x");
    await tester.tap(find.text(S.login));
    await tester.pumpAndSettle();
    expect(find.text(S.insecureServerBody), findsNothing,
        reason: "aucun avertissement pour une URL https://");
  });

  testWidgets("T8 : bannière — http:// visible, https:// absente",
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: appShell(serverUrl: "http://x", child: Text("home"))));
    await tester.pumpAndSettle();
    expect(find.text(S.insecureServer), findsOneWidget,
        reason: "bannière persistante pour http://");
    await tester.pumpWidget(
        MaterialApp(home: appShell(serverUrl: "https://x", child: Text("home"))));
    await tester.pumpAndSettle();
    expect(find.text(S.insecureServer), findsNothing,
        reason: "aucune bannière pour https://");
  });
}

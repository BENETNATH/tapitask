// Spec 2026-11-27 — AdminScreen : couverture des comportements réels
// (chargement, erreur, création, double-submit, toggles menu, reset mdp).
// Zéro changement de code production.
import "dart:async";
import "dart:convert";

import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:material_ui/material_ui.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/admin_screen.dart";

void main() {
  testWidgets("chargement initial : un ListTile par user, icône et "
      "sous-titre selon is_active / is_admin", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/admin/users" && request.method == "GET") {
        return http.Response(jsonEncode([
          {"id": "u1", "email": "a@x.fr", "is_active": true, "is_admin": true},
          {"id": "u2", "email": "b@x.fr", "is_active": false, "is_admin": false},
        ]), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();

    expect(find.text("a@x.fr"), findsOneWidget);
    expect(find.text("b@x.fr"), findsOneWidget);
    expect(find.text("admin · actif"), findsOneWidget,
        reason: "admin actif : sous-titre avec préfixe « admin · »");
    expect(find.text("désactivé"), findsOneWidget,
        reason: "inactif non-admin : sous-titre sans préfixe");
    expect(find.byIcon(Icons.person), findsOneWidget,
        reason: "user actif : icône person");
    expect(find.byIcon(Icons.person_off), findsOneWidget,
        reason: "user inactif : icône person_off");
    expect(tester.takeException(), isNull,
        reason: "le chargement ne plante pas");
    await state.db.close();
  });

  testWidgets(
      "erreur de chargement : GET /admin/users → 500 → message d'erreur "
      "rouge en bas (bottomSheet), pas de crash", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      return http.Response(jsonEncode({"detail": "boom-server"}), 500);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    // Pas de pumpAndSettle ici : en cas d'erreur, _users reste null → le
    // CircularProgressIndicator tourne indéfiniment (animation permanente).
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull,
        reason: "l'échec de chargement est géré, pas d'exception non gérée");
    expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            w.data == "boom-server" &&
            w.style?.color == Colors.red),
        findsOneWidget,
        reason: "le message d'erreur est affiché en rouge en bas");
    await state.db.close();
  });

  testWidgets("créer un compte : dialog → POST /admin/users avec le bon "
      "body → dialog fermé + liste rechargée", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    Map<String, dynamic>? postBody;
    var gets = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/admin/users" && request.method == "POST") {
        postBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/admin/users" && request.method == "GET") {
        gets++;
        return http.Response(
            jsonEncode([
              {"id": "u1", "email": "a@x.fr", "is_active": true, "is_admin": false}
            ]),
            200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();
    expect(gets, 1, reason: "chargement initial");

    await tester.tap(find.text(S.createAccount));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), "new@x.fr");
    await tester.enterText(find.byType(TextField).at(1), "secret123");
    await tester.tap(find.text(S.create));
    await tester.pumpAndSettle();

    expect(postBody, isNotNull, reason: "le POST doit partir");
    expect(postBody!["email"], "new@x.fr");
    expect(postBody!["password"], "secret123");
    expect(postBody!["is_admin"], false,
        reason: "le switch Admin reste off par défaut");
    expect(find.byType(AlertDialog), findsNothing,
        reason: "le dialog se ferme après succès");
    expect(gets, 2, reason: "la liste est rechargée après la création");
    await state.db.close();
  });

  testWidgets("double-submit : 2e tap sur « Créer » pendant le 1er POST "
      "→ exactement 1 POST (guard _creating)", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    final gate = Completer<void>();
    var posts = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/admin/users" && request.method == "POST") {
        posts++;
        await gate.future; // POST suspendu : le 2e tap arrive pendant
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/admin/users" && request.method == "GET") {
        return http.Response(jsonEncode([]), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.tap(find.text(S.createAccount));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), "new@x.fr");
    await tester.enterText(find.byType(TextField).at(1), "secret123");
    await tester.tap(find.text(S.create));
    await tester.pump();
    await tester.tap(find.text(S.create)); // 2e submit pendant le 1er POST
    await tester.pump();

    expect(posts, 1,
        reason: "S3 (prod4) : _creating bloque le second POST");

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing,
        reason: "le dialog se ferme quand le POST aboutit");
    await state.db.close();
  });

  testWidgets("toggle actif via menu ⋮ : PATCH /admin/users/<id> "
      "{\"is_active\": false} + liste rechargée", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    String? patchPath;
    Map<String, dynamic>? patchBody;
    var gets = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.method == "PATCH") {
        patchPath = request.url.path;
        patchBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/admin/users" && request.method == "GET") {
        gets++;
        return http.Response(jsonEncode([
          {"id": "u1", "email": "a@x.fr", "is_active": true, "is_admin": false}
        ]), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.deactivate));
    await tester.pumpAndSettle();

    expect(patchPath, "/admin/users/u1");
    expect(patchBody, {"is_active": false},
        reason: "désactiver : PATCH {is_active: false}");
    expect(gets, 2, reason: "la liste est rechargée après l'action");
    await state.db.close();
  });

  testWidgets("toggle admin via menu ⋮ : PATCH {\"is_admin\": true} + "
      "liste rechargée", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    String? patchPath;
    Map<String, dynamic>? patchBody;
    var gets = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.method == "PATCH") {
        patchPath = request.url.path;
        patchBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/admin/users" && request.method == "GET") {
        gets++;
        return http.Response(jsonEncode([
          {"id": "u1", "email": "a@x.fr", "is_active": true, "is_admin": false}
        ]), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.promoteAdmin));
    await tester.pumpAndSettle();

    expect(patchPath, "/admin/users/u1");
    expect(patchBody, {"is_admin": true},
        reason: "promouvoir : PATCH {is_admin: true}");
    expect(gets, 2, reason: "la liste est rechargée après l'action");
    await state.db.close();
  });

  testWidgets("reset password via menu ⋮ : dialog → PATCH {\"password\": "
      "...} → dialog fermé", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    String? patchPath;
    Map<String, dynamic>? patchBody;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.method == "PATCH") {
        patchPath = request.url.path;
        patchBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/admin/users" && request.method == "GET") {
        return http.Response(jsonEncode([
          {"id": "u1", "email": "a@x.fr", "is_active": true, "is_admin": false}
        ]), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(home: AdminScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.resetPassword));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "NewPass1");
    await tester.tap(find.text(S.apply));
    await tester.pumpAndSettle();

    expect(patchPath, "/admin/users/u1");
    expect(patchBody, {"password": "NewPass1"},
        reason: "reset : PATCH {password: ...}");
    expect(find.byType(AlertDialog), findsNothing,
        reason: "le dialog de reset se ferme après succès");
    await state.db.close();
  });
}

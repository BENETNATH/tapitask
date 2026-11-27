// Spec 2026-11-27 — ShareScreen : couverture des comportements réels
// (chargement, code d'invitation + presse-papier, ajout/re rôle/retrait
// de membre, email vide, erreur réseau). Zéro changement de production.
import "dart:convert";

import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:material_ui/material_ui.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/share_screen.dart";

const _members = [
  {"user_id": "u1", "email": "owner@x.fr", "role": "owner"},
  {"user_id": "u2", "email": "mem@x.fr", "role": "viewer"},
];

void main() {
  testWidgets("chargement initial : membres affichés, owner sans menu "
      "rôle/suppression, autres avec", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    expect(find.text("owner@x.fr"), findsOneWidget);
    expect(find.text("mem@x.fr"), findsOneWidget);
    expect(find.byIcon(Icons.stars), findsOneWidget,
        reason: "owner : icône stars");
    expect(find.byIcon(Icons.person), findsOneWidget,
        reason: "membre non-owner : icône person");
    expect(find.text(S.noMembers), findsNothing,
        reason: "la liste est non vide");
    // Owner : ni dropdown de rôle, ni bouton suppression → seul le
    // dropdown du membre viewer + le selecteur de rôle de la ligne
    // « ajouter » existent.
    expect(find.byType(DropdownButton<String>), findsNWidgets(2),
        reason: "1 dropdown d'ajout + 1 dropdown du membre viewer "
            "(aucun pour l'owner)");
    expect(find.byTooltip(S.remove), findsOneWidget,
        reason: "seul le membre non-owner a un bouton de retrait");
    expect(tester.takeException(), isNull,
        reason: "le chargement ne plante pas");
    await state.db.close();
  });

  testWidgets("générer un code : POST /invites {hours: 48} → code affiché ; "
      "tap dessus → Clipboard + SnackBar « Code copié »", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    Map<String, dynamic>? inviteBody;
    final clipCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == "Clipboard.setData") clipCalls.add(call);
      return null;
    });
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/lists/l1/invites" &&
          request.method == "POST") {
        inviteBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({"invite_id": "ABC123"}), 200);
      }
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    await tester.tap(find.text(S.generateCode));
    await tester.pumpAndSettle();

    expect(inviteBody, {"hours": 48}, reason: "POST /invites avec hours: 48");
    expect(find.text("ABC123"), findsOneWidget,
        reason: "le code s'affiche après génération");

    await tester.tap(find.text("ABC123"));
    await tester.pumpAndSettle();

    expect(clipCalls, hasLength(1),
        reason: "le tap sur le code appelle le presse-papier");
    final args = clipCalls.single.arguments as Map<dynamic, dynamic>;
    expect(args["text"], "ABC123",
        reason: "le contenu du presse-papier est le code");
    expect(find.text(S.codeCopied), findsOneWidget,
        reason: "le SnackBar « Code copié » s'affiche");
    await state.db.close();
  });

  testWidgets("ajouter un membre par email : POST /members {email, role} → "
      "champ vidé + liste rechargée", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    Map<String, dynamic>? postBody;
    var posts = 0;
    var gets = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/lists/l1/members" &&
          request.method == "POST") {
        posts++;
        postBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        gets++;
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();
    expect(gets, 1, reason: "chargement initial");

    await tester.tap(find.byType(DropdownButton<String>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.roleEditor));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "new@x.fr");
    await tester.tap(find.byTooltip(S.addMember));
    await tester.pumpAndSettle();

    expect(posts, 1, reason: "l'ajout envoie un seul POST");
    expect(postBody, {"email": "new@x.fr", "role": "editor"});
    expect(
        (tester.widget<TextField>(find.byType(TextField))).controller!.text,
        "",
        reason: "le champ email est vidé après succès");
    expect(gets, 2, reason: "la liste des membres est rechargée");
    await state.db.close();
  });

  testWidgets("email vide : le bouton d'ajout ne fait rien (aucun appel "
      "réseau)", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    var posts = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.method == "POST") posts++;
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(S.addMember));
    await tester.pumpAndSettle();

    expect(posts, 0,
        reason: "email vide → _addMember retourne avant tout appel réseau");
    await state.db.close();
  });

  testWidgets("changer le rôle d'un membre : dropdown → PATCH "
      "/members/<user_id> {role: editor} + rechargement", (tester) async {
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
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        gets++;
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    // Le dropdown du membre (le 2e : le 1er est celui de la ligne d'ajout).
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.roleEditor));
    await tester.pumpAndSettle();

    expect(patchPath, "/lists/l1/members/u2");
    expect(patchBody, {"role": "editor"},
        reason: "changement de rôle : PATCH {role: ...}");
    expect(gets, 2, reason: "la liste des membres est rechargée");
    await state.db.close();
  });

  testWidgets("retirer un membre : tap icône suppression → DELETE "
      "/members/<user_id> + rechargement", (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    String? deletePath;
    String? deleteMethod;
    var gets = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.method == "DELETE") {
        deletePath = request.url.path;
        deleteMethod = request.method;
        return http.Response(jsonEncode({}), 200);
      }
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        gets++;
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(S.remove));
    await tester.pumpAndSettle();

    expect(deleteMethod, "DELETE");
    expect(deletePath, "/lists/l1/members/u2");
    expect(gets, 2, reason: "la liste des membres est rechargée");
    await state.db.close();
  });

  testWidgets(
      "erreur réseau : POST /invites → 500 → _error affiché, pas de crash",
      (tester) async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/lists/l1/invites" &&
          request.method == "POST") {
        return http.Response(jsonEncode({"detail": "invite-boom"}), 500);
      }
      if (request.url.path == "/lists/l1/members" &&
          request.method == "GET") {
        return http.Response(jsonEncode(_members), 200);
      }
      return http.Response("not found", 404);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ShareScreen(state: state, listId: "l1")));
    await tester.pumpAndSettle();

    await tester.tap(find.text(S.generateCode));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: "l'échec réseau ne plante pas");
    expect(find.text("invite-boom"), findsOneWidget,
        reason: "le message d'erreur est affiché en bas de la liste");
    await state.db.close();
  });
}

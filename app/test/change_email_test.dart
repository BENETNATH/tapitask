import "dart:convert";
import "dart:io";

import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/sync_service.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/settings_screen.dart";

/// Spec 2026-11-22 §6 : ligne Email de la section Compte + dialogues de
/// changement (demande / collage du code, champ 2FA, erreurs).
///
/// Les requêtes HTTP passent par un vrai serveur local (127.0.0.1) capturé.
/// Le binding de test mocke le HttpClient global (tout = 400) : c'est
/// désactivé AVANT la création de ApiClient (le client est capté à la
/// construction) et tout tourne dans tester.runAsync (FakeAsync par défaut).

class _Request {
  final String path;
  final Map<String, dynamic>? body;
  _Request(this.path, this.body);
}

Future<HttpServer> _mockServer(
    List<_Request> requests,
    Map<String, dynamic> Function(String path) responder) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final raw = await utf8.decoder.bind(req).join();
    requests.add(_Request(
        req.uri.path,
        raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>));
    final reply = responder(req.uri.path);
    req.response.statusCode = reply["status"] as int? ?? 200;
    final json = reply["json"];
    if (json != null) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(json));
    }
    await req.response.close();
  });
  return server;
}

Future<AppState> _stateWithServer(HttpServer server,
    {String? email, String? pendingEmail, bool totp = false}) async {
  final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
  final api = ApiClient("http://127.0.0.1:${server.port}");
  api.accessToken = "test-token";
  state.api = api;
  // init() n'est pas appelé en test : sync est un late final que
  // reloadProfile() utilise.
  state.sync = SyncService(
      api: api, db: state.db, onChanged: state.notifyListeners);
  state.email = email;
  state.pendingEmail = pendingEmail;
  state.totp = totp;
  return state;
}

Map<String, dynamic> _me({String? pending}) => {
      "id": "00000000-0000-0000-0000-000000000001",
      "email": "a@b.fr",
      "is_admin": false,
      "settings": <String, dynamic>{},
      "pending_email": pending,
      "totp": false,
    };

Future<void> _pumpSettings(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(720, 1280);
  tester.view.devicePixelRatio = 2.0;
  await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: SettingsScreen(state: state)));
  await tester.pumpAndSettle();
  // la section Compte est en bas de la liste (construction paresseuse)
  await tester.scrollUntilVisible(find.text("a@b.fr"), 300);
}

/// Setup serveur + état + interaction dans un seul bloc async réel, avec le
/// mock HttpClient du binding désactivé le temps du test. [requests] est
/// capté par le serveur et visible après le bloc pour les assertions.
Future<void> _flow(
    WidgetTester tester,
    List<_Request> requests,
    Future<void> Function(AppState state) body, {
    Map<String, dynamic> Function(String path) responder = _responder,
    List<String> waitForPaths = const []}) async {
  final prev = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    await tester.runAsync(() async {
      final server = await _mockServer(requests, responder);
      final state = await _stateWithServer(server, email: "a@b.fr");
      await _pumpSettings(tester, state);
      await body(state);
      // le round-trip HTTP du dialogue prend du temps réel : attendre la
      // capture (POST + reloadProfile) avant de fermer le serveur (sinon le
      // connect en cours est RST).
      for (var i = 0;
          i < 50 &&
          !waitForPaths.every((p) => requests.any((r) => r.path == p));
          i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await server.close();
    });
  } finally {
    HttpOverrides.global = prev;
  }
}

void main() {
  testWidgets("§6 : la ligne Email affiche l'email du profil (connecté)",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <_Request>[];
    await _flow(tester, requests, (state) async {
      expect(find.text("a@b.fr"), findsOneWidget,
          reason: "la ligne Email doit afficher l'email du profil");
      // la ligne serveur reste en dessous
      expect(find.text(state.api.baseUrl), findsOneWidget);
    });
    expect(requests, isEmpty);
  });

  testWidgets("§6 : sous-titre « en attente » quand pendingEmail est set",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <_Request>[];
    await _flow(tester, requests, (state) async {
      state.pendingEmail = "new@b.fr";
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(S.emailChangePending), findsOneWidget);
    });
  });

  testWidgets(
      "§6 : dialogue non-pending envoie le bon JSON à /auth/change-email",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <_Request>[];
    late AppState state;
    await _flow(tester, requests, (s) async {
      state = s;
      await tester.tap(find.text("a@b.fr"));
      await tester.pumpAndSettle();
      // champs : nouvel email, mot de passe (pas de 2FA : totp false)
      await tester.enterText(find.byType(TextField).at(0), "new@x.fr");
      await tester.enterText(find.byType(TextField).at(1), "MonPassw0rd!");
      await tester.tap(find.text(S.ok));
      await tester.pumpAndSettle();
    },
        waitForPaths: ["/auth/change-email", "/auth/me"],
        responder: (p) => p == "/auth/me"
            ? {"json": _me(pending: "new@x.fr")}
            : {"status": 202});
    final change =
        requests.where((r) => r.path == "/auth/change-email").toList();
    expect(change.length, 1);
    expect(change.single.body, {
      "new_email": "new@x.fr",
      "password": "MonPassw0rd!",
    });
    // succès -> reloadProfile : l'état pending apparaît sur la ligne Email
    expect(state.pendingEmail, "new@x.fr");
  });

  testWidgets("§6 : dialogue pending envoie le code à /auth/verify-email",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <_Request>[];
    late AppState state;
    await _flow(tester, requests, (s) async {
      state = s;
      s.pendingEmail = "new@x.fr";
      s.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.text("a@b.fr"));
      await tester.pumpAndSettle();
      // un seul champ : le code
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), "ABCD-1234");
      await tester.tap(find.text(S.ok));
      await tester.pumpAndSettle();
    }, waitForPaths: ["/auth/verify-email", "/auth/me"]);
    expect(requests.any((r) => r.path == "/auth/change-email"), isFalse);
    final verify =
        requests.where((r) => r.path == "/auth/verify-email").toList();
    expect(verify.length, 1);
    expect(verify.single.body, {"token": "ABCD-1234"});
    // succès -> reloadProfile : l'attente disparaît
    expect(state.pendingEmail, isNull);
  });

  testWidgets("§6 : le champ 2FA n'apparaît que si totp=true",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    for (final totp in [false, true]) {
      final requests = <_Request>[];
      await _flow(tester, requests, (state) async {
        state.totp = totp;
        state.notifyListeners();
        await tester.pumpAndSettle();
        await tester.tap(find.text("a@b.fr"));
        await tester.pumpAndSettle();
        expect(find.text(S.totpCode),
            totp ? findsOneWidget : findsNothing,
            reason: "le champ 2FA doit être affiché seulement si totp=true");
        await tester.tap(find.text(S.cancel));
        await tester.pumpAndSettle();
      });
    }
  });

  testWidgets("§6 : l'erreur 409 est affichée dans le dialogue",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <_Request>[];
    await _flow(tester, requests, (state) async {
      await tester.tap(find.text("a@b.fr"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), "taken@x.fr");
      await tester.enterText(find.byType(TextField).at(1), "MonPassw0rd!");
      await tester.tap(find.text(S.ok));
      await tester.pumpAndSettle();
    },
        waitForPaths: ["/auth/change-email"],
        responder: (p) => {
              "status": 409,
              "json": {"detail": "Cet email est déjà utilisé"},
            });
    await tester.pumpAndSettle();
    // le dialogue reste ouvert avec le message d'erreur dédié
    expect(find.text(S.emailAlreadyUsed), findsOneWidget);
  });
}

Map<String, dynamic> _responder(String path) {
  if (path == "/auth/me") return {"json": _me()};
  return {"status": 202};
}

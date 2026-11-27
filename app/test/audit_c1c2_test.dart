// Audit 2026-11-24 — tests des corrections C1.x/C2.x côté app.
import "dart:convert";
import "dart:io" show File;

import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:flutter/services.dart" show PlatformException;
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/sync_service.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/main.dart" show appShell;
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";
import "package:tapitask/ui/login_screen.dart";

/// Storage qui lève (web http:// hors secure context, Android sans Keystore).
class _ThrowingSecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({required String key, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    throw PlatformException(code: "secure-storage-unavailable");
  }

  @override
  Future<void> write({required String key, required String? value,
      AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
      WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    throw PlatformException(code: "secure-storage-unavailable");
  }

  @override
  Future<void> delete({required String key, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    throw PlatformException(code: "secure-storage-unavailable");
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- C1.7 : compte -------------------------------------------------

  test("C1.7 : register 202 → EmailVerificationRequired, aucun token", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final api = ApiClient("https://srv",
        client: MockClient((request) async => http.Response("", 202)));
    await expectLater(
        api.register("a@b.fr", "LongPassw0rd!x"),
        throwsA(isA<EmailVerificationRequired>()));
    expect(api.accessToken, isNull, reason: "pas de faux succès");
    expect(api.refreshTokenValue, isNull);
    expect(await FlutterSecureStorage().read(key: "access_token"), isNull,
        reason: "rien n'est persisté sur 202");
  });

  test("C1.7 : persist(null) → clés retirées (et non écrites \"\")", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {"access_token": "a", "refresh_token": "r"});
    final api = ApiClient("https://srv");
    api.accessToken = null;
    api.refreshTokenValue = null;
    await api.persist();
    expect(await FlutterSecureStorage().read(key: "access_token"), isNull);
    expect(await FlutterSecureStorage().read(key: "refresh_token"), isNull);
  });

  test("C1.7 : \"\" persisté avant le fix ≡ absent au load", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {"access_token": "", "refresh_token": ""});
    final api = await ApiClient.load();
    expect(api.accessToken, isNull);
    expect(api.refreshTokenValue, isNull);
  });

  testWidgets(
      "C1.7 : verify-email sans baseUrl (installation fraîche) → message, pas de crash",
      (tester) async {
    // Installation fraîche : state.api sans baseUrl, champ URL serveur vide.
    // En production, le POST avec baseUrl "" donne Uri.parse("/auth/verify-email")
    // = URI relative (ni scheme ni host) → dart:io (HttpClient.openUrl) lève
    // ArgumentError("No host specified in URI /auth/verify-email") — vérifié
    // sur l'hôte. Le binding de test mocke HttpClient (tout → 400) et masquerait
    // ce throw : le MockClient injecté reproduit donc le même throw dès que
    // l'URI n'a pas de scheme.
    // AVANT le fix, _verifyEmail n'avait qu'un catch « on ApiException » :
    // l'ArgumentError n'était pas attrapé → erreur async non gérée = crash
    // (ce test est ROUGE sur ce code). APRÈS le fix : _applyServerUrl() avant
    // le POST + catch générique (e) → message d'erreur affiché via S.loginFailed(e).
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient(
        "",
        client: MockClient((request) async {
      if (!request.url.hasScheme) {
        throw ArgumentError("No host specified in URI ${request.url}");
      }
      return http.Response("", 200);
    }));
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.tap(find.text(S.verifyEmail));
    await tester.pumpAndSettle();
    expect(find.text(S.codeFromEmail), findsOneWidget);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        "123456");
    await tester.tap(find.text("Valider"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: "C1.7 : l'erreur ne doit pas crasher l'app");
    expect(
        find.byWidgetPredicate(
            (w) => w is Text && (w.data?.startsWith("Échec :") ?? false)),
        findsOneWidget,
        reason: "C1.7 : le catch générique affiche le message d'erreur");
    await state.db.close();
  });

  // ---- C2.1 : secure storage en échec --------------------------------

  test("C2.1 : storage en échec → load() sans crash, tokens en mémoire",
      () async {
    SharedPreferences.setMockInitialValues({"server_url": "https://srv"});
    final real = ApiClient.secureStorage;
    try {
      ApiClient.secureStorage = _ThrowingSecureStorage();
      final api = await ApiClient.load();
      expect(api.accessToken, isNull);
      expect(api.refreshTokenValue, isNull);
      expect(api.secureStorageUnavailable, isTrue);
    } finally {
      ApiClient.secureStorage = real;
    }
  });

  test("C2.1 : AndroidManifest allowBackup=\"false\"", () {
    final manifest = File("android/app/src/main/AndroidManifest.xml")
        .readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
  });

  // ---- C2.7 : refresh concurrent + session expirée -------------------

  test("C2.7 : deux 401 simultanés → exactement UN /auth/refresh", () async {
    var refreshCalls = 0;
    final api = ApiClient("https://srv",
        client: MockClient((request) async {
      if (request.url.path == "/auth/refresh") {
        refreshCalls++;
        // Le 2e 401 doit arriver PENDANT ce refresh (single-flight).
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response(
            jsonEncode({"access_token": "new-a", "refresh_token": "new-r"}),
            200,
            headers: const {"content-type": "application/json"});
      }
      // Après le refresh, les mêmes routes répondent 200 (le retry doit
      // aboutir — sinon l'exception masquerait le comptage).
      if (refreshCalls > 0) {
        return http.Response(jsonEncode({"ok": true}), 200);
      }
      return http.Response(jsonEncode({"detail": "nope"}), 401);
    }));
    api.accessToken = "old";
    api.refreshTokenValue = "old-r";
    await Future.wait([api.get("/x"), api.get("/y")]);
    expect(refreshCalls, 1,
        reason: "single-flight : le 2e 401 attend le 1er refresh");
    expect(api.accessToken, "new-a");
  });

  test("C2.7 : refresh → 401 → tokens nuls, persistés retirés, app notifiée",
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {"access_token": "a", "refresh_token": "r"});
    var expired = 0;
    final api = ApiClient("https://srv",
        client: MockClient((request) async {
      if (request.url.path == "/auth/refresh") {
        return http.Response(jsonEncode({"detail": "expired"}), 401);
      }
      return http.Response(jsonEncode({"detail": "nope"}), 401);
    }));
    api.accessToken = "a";
    api.refreshTokenValue = "r";
    api.onSessionExpired = () => expired++;
    await expectLater(api.get("/x"), throwsA(isA<ApiException>()));
    expect(api.accessToken, isNull);
    expect(api.refreshTokenValue, isNull);
    expect(expired, 1);
    expect(await FlutterSecureStorage().read(key: "access_token"), isNull,
        reason: "le retrait doit être persisté");
    expect(await FlutterSecureStorage().read(key: "refresh_token"), isNull);
  });

  // ---- C1.6 : timeout http + init non bloquant -----------------------

  test("C1.6 : timeout http effectif (réponse trop lente → exception)",
      () async {
    final api = ApiClient(
        "https://srv",
        timeout: const Duration(milliseconds: 300),
        client: MockClient((request) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return http.Response("{}", 200);
    }));
    final sw = Stopwatch()..start();
    await expectLater(api.get("/slow"), throwsA(isA<Exception>()));
    expect(sw.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: "le timeout doit couper la requête, pas l'attendre");
  });

  test("C1.6 : init hors-ligne → retour rapide + réglages en cache", () async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({
      "server_url": "https://unreachable.invalid",
      "cached_settings": jsonEncode({"lang": "en", "theme": "dark"}),
    });
    FlutterSecureStorage.setMockInitialValues(
        {"access_token": "a", "refresh_token": "r"});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    final sw = Stopwatch()..start();
    await state.init();
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: "init ne bloque que sur la partie locale");
    expect(state.settings["theme"], "dark",
        reason: "C1.6 : les réglages en cache sont TOUJOURS appliqués");
    expect(state.settings["lang"], "en");
    // Pas de timer résiduel (reconnect WS) dans les tests suivants.
    state.dispose();
  });

  // ---- C1.1a : label vide → pas d'item --------------------------------

  test("C1.1a : ligne sans libellé (mots-clés seuls) → pas d'item", () async {
    S.setLocale("fr");
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("");
    final listId = await state.createList("courses", localOnly: true);
    await state.addQuickItems(listId, "demain");
    await state.addQuickItems(listId, "#courses");
    final items = await state.db.itemsOf(listId);
    expect(items, isEmpty,
        reason: "C1.1a (A1) : libellé vide → ni item local ni event outbox");
    // Une ligne normale passe toujours.
    await state.addQuickItems(listId, "lait");
    expect((await state.db.itemsOf(listId)).length, 1);
  });

  // ---- C2.8 : changement de compte → purge locale ---------------------

  test("C2.8 : login B après A → tables vides + last_sync nul", () async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({
      "account_email": "a@x.fr",
      "last_sync": "2026-01-01T00:00:00Z",
    });
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    final listId = await state.createList("A", localOnly: true);
    await state.db.addItem("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", listId,
        "Pain", 0, DateTime.now().toUtc());
    expect((await state.db.itemsOf(listId)).length, 1);

    // Le profil du compte B est chargé (email != compte précédent).
    state.email = "b@x.fr";
    await state.onAccountSwitch();

    expect((await state.db.itemsOf(listId)).length, 0,
        reason: "C2.8 : les items du compte A ne doivent pas survivre");
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString("last_sync"), isNull,
        reason: "last_sync réinitialisé avant le fullSync du compte B");
    expect(prefs.getString("account_email"), "b@x.fr");
  });

  // ---- C2.9 : push /sync avec since -----------------------------------

  test("C2.9 : push envoie since=last_sync quand disponible", () async {
    SharedPreferences.setMockInitialValues(
        {"last_sync": "2026-11-01T00:00:00Z"});
    final bodies = <Map<String, dynamic>>[];
    final api = ApiClient("https://srv", client: MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
          jsonEncode({"rejected": <String>[], "changes": <Object>[]}), 200);
    }));
    api.accessToken = "a";
    final db = AppDb.forTesting(NativeDatabase.memory());
    await db.upsertList(LocalListsCompanion(
      id: const Value("11111111-2222-3333-4444-555555555555"),
      title: const Value("N"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(true),
      localOnly: const Value(false),
    ));
    final sync = SyncService(api: api, db: db);
    await sync.fullSync();
    expect(bodies.isNotEmpty, isTrue);
    final push = bodies.first;
    expect(push["events"], isNotEmpty, reason: "le 1er POST est le push");
    expect(push["since"], "2026-11-01T00:00:00Z",
        reason: "C2.9 : le push porte since (le serveur renvoie des "
            "changes immédiatement jetés avant le _pull)");
  });

  // ---- C2.2 : bannière http:// ---------------------------------------

  testWidgets("C2.2 : bannière http:// dans Material + SafeArea",
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: appShell(serverUrl: "http://x", child: const Text("home"))));
    await tester.pumpAndSettle();
    expect(find.text(S.insecureServer), findsOneWidget);
    // C2.2 : la bannière est dans un SafeArea (elle ne passe plus sous la
    // barre de statut) qui est lui-même sur une Material.
    expect(
        find.descendant(
            of: find.byType(SafeArea), matching: find.text(S.insecureServer)),
        findsOneWidget,
        reason: "bannière encapsulée dans SafeArea(top)");
    expect(
        find.descendant(
            of: find.byType(Material), matching: find.text(S.insecureServer)),
        findsOneWidget,
        reason: "bannière sur une Material (barrière)");
  });

  // ---- C2.3 : couleur invalide ---------------------------------------

  testWidgets("C2.3 : list.color invalide → pas de crash, titre rendu",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    const listId = "11111111-2222-3333-4444-555555555555";
    await db.upsertList(LocalListsCompanion(
      id: const Value(listId),
      title: const Value("Achats"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
      color: const Value("#zz"), // invalide : int.parse levait une exception
    ));
    final state = AppState(db: db);
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: listId)));
    await tester.pumpAndSettle();
    expect(find.text("Achats"), findsWidgets,
        reason: "C2.3 : rendu normal malgré la couleur invalide");
    await db.close();
  });
}

// Audit 2026-11-24 lot prod3 — tests corrections app (1.1, 1.2, 1.3, 1.4,
// 1.5, 2.2, 2.5, 3.7).
import "dart:async";
import "dart:convert";
import "dart:io";

import "package:drift/drift.dart" hide isNull, isNotNull;
import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/android_updater.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/sync_service.dart";
import "package:tapitask/data/update_service.dart";
import "package:tapitask/data/windows_updater.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/main.dart" show ChecklistsApp, appState;
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/login_screen.dart";
import "package:tapitask/ui/update_dialog.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 300));

  // ---- 1.1 : crash boot — showDialog hors MaterialApp -----------------

  testWidgets(
      "1.1 : MAJ au boot → le dialog s'ouvre sans exception "
      "(navigator key, pas le context du state)", (tester) async {
    // path_provider → db fichier dans /tmp (appState global = AppDb() réel,
    // LazyDatabase : ouverture à la 1re query).
    Directory("/tmp/opencode/tapitask-dbtest").createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel("plugins.flutter.io/path_provider"),
            (call) async =>
                call.method == "getApplicationDocumentsDirectory"
                    ? "/tmp/opencode/tapitask-dbtest"
                    : null);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    try {
      // runAsync : init() passe par de vrais canaux platform (widget launch
      // URI, path_provider, DB en background isolate) — dans la zone
      // FakeAsync de testWidgets, les réponses de canaux n'arrivent jamais
      // (le test pendrait) ; runAsync s'exécute sur la vraie boucle d'événements.
      await tester.runAsync(() => appState.init());
      appState.setPendingBootUpdate(const UpdateInfo(
        clientAvailable: true,
        latest: "9.9.9",
        clientCurrent: "0.1.0",
        serverRequired: false,
      ));
      await tester.pumpWidget(const ChecklistsApp());
      // Le dialog n'apparaît qu'au post-frame callback (1re frame).
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: "1.1 : showDialog hors MaterialApp crashait post-frame");
      expect(find.byType(UpdateDialog), findsOneWidget);
    } finally {
      // dispose() ferme déjà la DB — un 2e close() concurrent provoque un
      // ConcurrentModificationError dans drift (StreamQueryStore.close).
      appState.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel("plugins.flutter.io/path_provider"), null);
    }
  });

  // ---- 1.2 : UpdateDialog — état détenu par le dialog ----------------

  testWidgets(
      "1.2 : tap « Mettre à jour » → spinner + bouton désactivé, "
      "puis retour au bouton", (tester) async {
    S.setLocale("fr");
    final completer = Completer<void>();
    await tester.pumpWidget(
        MaterialApp(home: UpdateDialog(
            info: const UpdateInfo(
                clientAvailable: true,
                latest: "0.4.0",
                clientCurrent: "0.3.0",
                serverRequired: false),
            onUpdate: () => completer.future)));
    await tester.pump();
    expect(find.text(S.updateButton), findsOneWidget);

    await tester.tap(find.text(S.updateButton));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: "1.2 : spinner visible pendant le téléchargement");
    final updateButton =
        tester.widgetList<TextButton>(find.byType(TextButton)).first;
    expect(updateButton.onPressed, isNull,
        reason: "1.2 : bouton désactivé (pas de clics multiples)");

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.text(S.updateButton), findsOneWidget,
        reason: "le bouton revient après la fin du téléchargement");
  });

  testWidgets("1.2 : échec de l'update → erreur affichée dans le dialog",
      (tester) async {
    S.setLocale("fr");
    final failing = Completer<void>();
    await tester.pumpWidget(
        MaterialApp(home: UpdateDialog(
            info: const UpdateInfo(
                clientAvailable: true,
                latest: "0.4.0",
                clientCurrent: "0.3.0",
                serverRequired: false),
            onUpdate: () => failing.future)));
    await tester.pump();
    await tester.tap(find.text(S.updateButton));
    await tester.pump();
    failing.completeError(StateError("téléchargement interrompu"));
    await tester.pumpAndSettle();
    expect(find.textContaining("téléchargement interrompu"), findsOneWidget,
        reason: "1.2 : l'erreur s'affiche DANS le dialog (plus d'état parent)");
    expect(find.text(S.updateButton), findsOneWidget,
        reason: "le bouton est ré-activé après l'erreur");
  });

  // ---- 1.3 : saveSettings hors-ligne ----------------------------------

  test("1.3 : api en échec → réglage en cache + listeners AVANT le réseau",
      () async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return http.Response("{}", 503);
    }));
    var notified = 0;
    state.addListener(() => notified++);
    state.settings["hide_done"] = false;

    final sw = Stopwatch()..start();
    await state.saveSettings();
    sw.stop();

    expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)),
        reason: "1.3 : saveSettings ne bloque plus sur le timeout réseau");
    expect(notified, greaterThan(0),
        reason: "1.3 : les listeners sont notifiés avant la fin du PATCH");
    final prefs = await SharedPreferences.getInstance();
    final cached =
        jsonDecode(prefs.getString("cached_settings")!) as Map<String, dynamic>;
    expect(cached["hide_done"], false,
        reason: "1.3 : le réglage est en cache avant le PATCH serveur");
    // Le PATCH de fond s'exécute quand même (silencieux en échec).
    await drain();
    await state.db.close();
  });

  // ---- 1.4 : session, profil, WebSocket --------------------------------

  test("1.4a : init câble onSessionExpired ; handleSessionExpired "
      "réinitialise le profil et ferme le WS", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    await state.init();
    expect(state.api.onSessionExpired, isNotNull,
        reason: "1.4a : onSessionExpired branché dans init()");
    state.email = "a@x.fr";
    state.pendingEmail = "b@x.fr";
    state.isAdmin = true;
    state.totp = true;
    // Appeler le callback BRANCHÉ (pas le tearoff : `identical` est faux
    // entre deux tearoffs de la même méthode) — ça teste le câblage ET
    // l'effet.
    state.api.onSessionExpired!();
    expect(state.email, isNull);
    expect(state.pendingEmail, isNull);
    expect(state.isAdmin, isFalse);
    expect(state.totp, isFalse);
    expect(state.sync.connected, isFalse,
        reason: "1.4a : le WebSocket est fermé");
    state.dispose();
    await state.db.close();
  });

  test("1.4b : reloadProfile(required: true) échoué → rethrow ; "
      "sans required → avalé", () async {
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((request) async =>
            http.Response(jsonEncode({"detail": "boom"}), 500)));
    state.api.accessToken = "a";
    // reloadProfile touche sync.pollSeconds (poll_interval du settings par
    // défaut) — sans init(), le late final sync n'existe pas.
    state.sync = SyncService(api: state.api, db: state.db);
    await expectLater(state.reloadProfile(required: true),
        throwsA(isA<ApiException>()),
        reason: "1.4b : au login, un profil non chargé est fatal");
    await state.reloadProfile(); // ne lève pas
    await state.db.close();
  });

  testWidgets("1.4c : login échoué → Future<bool> false, erreur affichée, "
      "pas de navigation, pas de purge", (tester) async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      return http.Response(jsonEncode({"detail": "Invalid credentials"}), 401);
    }));
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), "a@x.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "pw");
    await tester.tap(find.text(S.login));
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data?.startsWith("Échec :") ?? false)),
        findsOneWidget,
        reason: "1.4b/c : l'erreur est affichée à l'écran");
    expect(find.text(S.login), findsOneWidget,
        reason: "on reste sur l'écran de login (pas de pushReplacement)");
    await state.db.close();
  });

  testWidgets("1.4c : _acceptInvite s'arrête si _submit échoue "
      "(pas de POST accept sans session)", (tester) async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    var acceptCalls = 0;
    state.api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path.contains("/accept")) {
        acceptCalls++;
        return http.Response("{}", 200);
      }
      return http.Response(jsonEncode({"detail": "Invalid credentials"}), 401);
    }));
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.haveInviteCode));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        "CODE123");
    await tester.tap(find.text("Valider"));
    await tester.pumpAndSettle();
    expect(acceptCalls, 0,
        reason: "1.4c : le POST accept n'est pas envoyé sans session");
    expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data?.startsWith("Échec :") ?? false)),
        findsOneWidget,
        reason: "l'échec du login est affiché");
    await state.db.close();
  });

  test("1.4d : listenRealtime 2× → 1 seul WS actif (aucun orphelin)",
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var open = 0;
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      open++;
      ws.listen((_) {}, onDone: () => open--);
    });
    final api = ApiClient("http://127.0.0.1:${server.port}");
    api.accessToken = "a";
    final db = AppDb.forTesting(NativeDatabase.memory());
    final sync = SyncService(api: api, db: db);
    await sync.listenRealtime();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sync.listenRealtime();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(open, 1,
        reason: "1.4d : l'ancien canal est fermé avant d'ouvrir le nouveau");
    sync.dispose();
    await server.close(force: true);
    await db.close();
  });

  // ---- 1.5 : curseur delta ancré sur server_time ------------------------

  test("1.5 : last_sync = server_time - 5 s même si newest > server_time",
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final serverTime = DateTime.utc(2026, 1, 15, 12, 0, 0);
    final api = ApiClient("https://srv", client: MockClient((request) async {
      return http.Response(jsonEncode({
        "changes": [
          {
            "kind": "item.sync",
            "id": "i1",
            "list_id": "l1",
            "label": "t",
            "done": false,
            "position": 0,
            // server_time + 4 s : l'horloge client était en avance.
            "updated_at": serverTime
                .add(const Duration(seconds: 4))
                .toIso8601String(),
          }
        ],
        "server_time": serverTime.toIso8601String(),
        "rejected": <String>[],
      }), 200);
    }));
    api.accessToken = "a";
    final sync = SyncService(api: api, db: db);
    await sync.fullSync();
    final prefs = await SharedPreferences.getInstance();
    final saved = DateTime.parse(prefs.getString("last_sync")!);
    expect(saved, serverTime.subtract(const Duration(seconds: 5)),
        reason:
            "1.5 : ancré sur l'horloge serveur (newest > server_time ignoré)");
    await db.close();
  });

  // ---- 2.2 : race dirty outbox + renameList hors session ----------------

  test("2.2 : mutation PENDANT le POST /sync → l'item reste dirty "
      "(repoussé au prochain sync)", () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final now = DateTime.now().toUtc();
    await db.upsertList(LocalListsCompanion(
      id: const Value("l1"),
      title: const Value("courses"),
      ownerId: const Value(""),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
    await db.addItem("i1", "l1", "lait", 0, now);
    var mutated = false;
    final api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/sync" && request.method == "POST") {
        // POST lent de PUSH d'items : l'utilisateur coche l'item PENDANT
        // l'appel réseau. Une seule fois, et seulement sur le push d'item
        // (pas le push de liste ni le pull, sinon l'item se re-salirait à
        // chaque sync et le 2e sync ne pourrait jamais le nettoyer).
        var isItemPush = false;
        try {
          final evs =
              (jsonDecode(request.body) as Map<String, dynamic>)["events"]
                  as List<dynamic>?;
          isItemPush = evs != null &&
              evs.any((e) =>
                  ((e as Map<String, dynamic>)["kind"] ?? "")
                      .toString()
                      .startsWith("item"));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (isItemPush && !mutated) {
          mutated = true;
          await db.setDone("i1", true, now.add(const Duration(seconds: 1)));
        }
        return http.Response(jsonEncode({
          "changes": <Map<String, dynamic>>[],
          "server_time": now.toIso8601String(),
          "rejected": <String>[],
        }), 200);
      }
      return http.Response(jsonEncode({"detail": "nope"}), 404);
    }));
    api.accessToken = "a";
    final sync = SyncService(api: api, db: db);
    await sync.fullSync();
    expect(mutated, isTrue,
        reason: "2.2 : la mutation a bien eu lieu PENDANT le push d'item");
    expect((await db.dirtyItems()).map((i) => i.id), contains("i1"),
        reason:
            "2.2 : la mutation pendant le POST n'est pas marquée propre");
    // Le prochain sync repousse l'item et le nettoie.
    await sync.fullSync();
    expect((await db.dirtyItems()).isEmpty, isTrue,
        reason: "2.2 : l'item muté est bien repoussé au sync suivant");
    await db.close();
  });

  test("2.2 : renameList hors session → le widget est rafraîchi en local",
      () async {
    SharedPreferences.setMockInitialValues({});
    var widgetUpdates = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel("home_widget"),
            (call) async {
      if (call.method.startsWith("updateWidget")) widgetUpdates++;
      return null;
    });
    try {
      final state =
          AppState(db: AppDb.forTesting(NativeDatabase.memory()));
      state.api = ApiClient(""); // pas de session
      state.sync = SyncService(api: state.api, db: state.db);
      final id = await state.createList("courses", localOnly: true);
      await state.renameList(id, "Courses 2");
      expect(widgetUpdates, greaterThan(0),
          reason: "2.2 : _refreshWidget est sorti du if « session active »");
      state.dispose();
      await state.db.close();
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel("home_widget"), null);
    }
  });

  // ---- 2.5 : updaters — Zip Slip, https, timeout -------------------------

  test("2.5 : Zip Slip — les entrées qui sortent du dossier sont refusées",
      () {
    const base = "/tmp/opencode/tapitask-upd";
    expect(isSafeZipEntry("../evil", baseDir: base), isFalse,
        reason: "2.5 : `../evil` s'échappe du dossier cible");
    expect(isSafeZipEntry("a/../../evil", baseDir: base), isFalse);
    expect(isSafeZipEntry("tapitask.exe", baseDir: base), isTrue);
    expect(isSafeZipEntry("assets/icon.ico", baseDir: base), isTrue);
  });

  test("2.5 : URL http:// refusée (APK)", () async {
    final info = const UpdateInfo(
      clientAvailable: true,
      latest: "0.4.0",
      clientCurrent: "0.3.0",
      apkUrl: "http://gh.io/tapitask.apk",
      serverRequired: false,
    );
    await expectLater(installApk(info), throwsA(isA<StateError>()),
        reason: "2.5 : seul le https est accepté pour le téléchargement");
  });

  test("2.5 : URL http:// refusée (Windows)", () async {
    final info = const UpdateInfo(
      clientAvailable: true,
      latest: "0.4.0",
      clientCurrent: "0.3.0",
      windowsUrl: "http://gh.io/tapitask.zip",
      serverRequired: false,
    );
    await expectLater(runSelfUpdate(info), throwsA(isA<StateError>()));
  });

  test("2.5 : checkForUpdates — timeout sur réponse lente → info neutre",
      () async {
    final api = ApiClient("");
    final client = MockClient((request) async {
      await Future<void>.delayed(const Duration(seconds: 5));
      return http.Response("{}", 200);
    });
    final sw = Stopwatch()..start();
    final info = await checkForUpdates(
        client: client,
        api: api,
        checkTimeout: const Duration(milliseconds: 200));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
        reason: "2.5 : le timeout coupe la requête, pas l'attendre");
    expect(info.latest, "", reason: "timeout → info neutre");
  });

  test("2.5 : checkForUpdates — asset http:// non retenu", () async {
    final api = ApiClient("");
    final client = MockClient((request) async {
      return http.Response(jsonEncode({
        "tag_name": "v9.9.9",
        "assets": [
          {
            "name": "tapitask-v9.9.9-android.apk",
            "browser_download_url": "http://gh.io/x.apk"
          }
        ],
      }), 200);
    });
    final info = await checkForUpdates(client: client, api: api);
    expect(info.apkUrl, isNull,
        reason: "2.5 : seul un asset https est proposé");
  });

  // ---- 3.7 : ApiClient — pas de boucle infinie ---------------------------

  test("3.7 : 401 persistant après refresh « réussi » → au plus 1 retry",
      () async {
    var gets = 0;
    var refreshes = 0;
    final api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/auth/refresh") {
        refreshes++;
        return http.Response(
            jsonEncode({"access_token": "a2", "refresh_token": "r2"}), 200);
      }
      if (request.method == "GET") gets++;
      return http.Response(jsonEncode({"detail": "nope"}), 401);
    }));
    api.accessToken = "a";
    api.refreshTokenValue = "r";
    await expectLater(api.get("/x"), throwsA(isA<ApiException>()),
        reason: "3.7 : le 2e 401 se propage au lieu de boucler");
    expect(gets, 2, reason: "appel initial + retry unique — pas de boucle");
    expect(refreshes, 1);
  });

  test("3.7 : importFile 401 persistant après refresh → au plus 1 retry",
      () async {
    var posts = 0;
    var refreshes = 0;
    final api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/auth/refresh") {
        refreshes++;
        return http.Response(
            jsonEncode({"access_token": "a2", "refresh_token": "r2"}), 200);
      }
      if (request.url.path == "/import") posts++;
      return http.Response(jsonEncode({"detail": "nope"}), 401);
    }));
    api.accessToken = "a";
    api.refreshTokenValue = "r";
    await expectLater(api.importFile("body"), throwsA(isA<ApiException>()),
        reason: "importFile : le 2e 401 se propage au lieu de boucler "
            "(le garde manquait avant l'extraction de _withRetry)");
    expect(posts, 2, reason: "appel initial + retry unique — pas de boucle");
    expect(refreshes, 1);
  });
}

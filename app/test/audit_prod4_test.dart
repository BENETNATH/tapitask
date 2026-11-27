// Audit 2026-11-24 lot prod4 — tests app (B1, M5, M6, M8, S2, S3).
// Spec : specs/2026-11-24-audit-prod4-corrections.md
import "dart:convert";

import "package:drift/native.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/sync_service.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/main.dart" show shouldShowBootUpdateDialog;
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/login_screen.dart";
import "package:tapitask/ui/settings_screen.dart";

/// Spy de SyncService : enregistre l'appel init() et no-ops le reste —
/// le flux testé est l'ordre des appels, pas le contenu du sync.
class _SpySync extends SyncService {
  final List<String> log;
  _SpySync(this.log)
      : super(
            api: ApiClient("https://srv"),
            db: AppDb.forTesting(NativeDatabase.memory()));

  @override
  Future<void> init() async {
    log.add("sync.init");
  }

  @override
  Future<void> fullSync() async {}

  @override
  Future<void> listenRealtime() async {}

  @override
  Future<void> stopRealtime() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---- B1 (D-1) : fuite inter-comptes si reloadProfile échoue ---------

  test("B1a : échec reloadProfile au boot → état déconnecté, PAS de sync",
      () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final events = <String>[];
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      events.add(req.url.path);
      if (req.url.path == "/auth/me") return http.Response("{}", 500);
      return http.Response("{}", 200);
    }));
    state.api.accessToken = "tok-b";
    state.api.refreshTokenValue = "ref-b";
    final spy = _SpySync(events);
    state.sync = spy;

    await state.initNetworkForTesting();

    expect(events, contains("/auth/me"));
    expect(events.where((p) => p.contains("/sync")), isEmpty,
        reason: "B1a : un profil en échec ne doit pas lancer le sync "
            "(données du compte précédent poussées)");
    expect(state.api.accessToken, isNull,
        reason: "B1a : tokens purgés → état déconnecté");
    expect(state.api.refreshTokenValue, isNull);
    expect(state.email, isNull);
    await state.db.close();
  });

  test("B1a : ordre — reloadProfile (me) AVANT sync.init", () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final events = <String>[];
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      if (req.url.path == "/auth/me") {
        events.add("me");
        return http.Response(jsonEncode({"email": "b@x.fr"}), 200);
      }
      return http.Response("{}", 200);
    }));
    state.api.accessToken = "tok-b";
    state.api.refreshTokenValue = "ref-b";
    state.sync = _SpySync(events);

    await state.initNetworkForTesting();

    final iMe = events.indexOf("me");
    final iSync = events.indexOf("sync.init");
    expect(iMe, isNonNegative);
    expect(iSync, isNonNegative,
        reason: "B1a : sync.init doit bien être appelé au boot");
    expect(iMe, lessThan(iSync),
        reason: "B1a : le profil est chargé AVANT le sync");
    expect(state.api.accessToken, "tok-b",
        reason: "profil OK → session conservée");
    await state.db.close();
  });

  testWidgets("B1b : login OK mais /auth/me en échec → tokens écrasés",
      (tester) async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      if (req.method == "POST" && req.url.path == "/auth/login") {
        return http.Response(
            jsonEncode({"access_token": "a", "refresh_token": "r"}), 200);
      }
      if (req.url.path == "/auth/me") return http.Response("{}", 500);
      return http.Response("{}", 200);
    }));
    state.sync = _SpySync([]);

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: LoginScreen(state: state),
        routes: {"/home": (_) => const SizedBox()}));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), "b@x.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "LongPassw0rd!x");
    await tester.tap(find.text(S.login));
    await tester.pumpAndSettle();

    expect(state.api.accessToken, isNull,
        reason: "B1b : le token persisté par _auth() est écrasé quand le "
            "profil échoue (avant fix : la session B restait active)");
    expect(state.api.refreshTokenValue, isNull);
    await state.db.close();
  });

  // ---- M5 : _loadToken valeur vide = null ------------------------------

  test("M5 : legacy \"\" en plain → null, clés absentes des deux stores",
      () async {
    SharedPreferences.setMockInitialValues(
        {"access_token": "", "refresh_token": ""});
    FlutterSecureStorage.setMockInitialValues({});
    final api = await ApiClient.load();
    expect(api.accessToken, isNull,
        reason: "M5 : une valeur vide ne donne pas un token non-null");
    expect(api.refreshTokenValue, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString("access_token"), isNull,
        reason: "clé plain supprimée");
    expect(prefs.getString("refresh_token"), isNull);
    expect(await FlutterSecureStorage().read(key: "access_token"), isNull,
        reason: "M5 : le vide n'est PAS migré en secure storage");
  });

  // ---- M6 : pas de dialog boot sur web ----------------------------------

  test("M6 : le dialog de MAJ au boot n'existe pas sur web", () {
    expect(
        shouldShowBootUpdateDialog(
            clientAvailable: true,
            isWeb: true,
            platform: TargetPlatform.windows),
        false,
        reason: "M6 : web (simulateur de windows) → pas de dialog");
    expect(
        shouldShowBootUpdateDialog(
            clientAvailable: true,
            isWeb: false,
            platform: TargetPlatform.windows),
        true);
    expect(
        shouldShowBootUpdateDialog(
            clientAvailable: true,
            isWeb: false,
            platform: TargetPlatform.android),
        true);
    expect(
        shouldShowBootUpdateDialog(
            clientAvailable: true,
            isWeb: false,
            platform: TargetPlatform.linux),
        false,
        reason: "desktop hors windows/android : pas de dialog (comportement "
            "existant)");
    expect(
        shouldShowBootUpdateDialog(
            clientAvailable: false,
            isWeb: false,
            platform: TargetPlatform.windows),
        false);
  });

  // ---- M8 (D-5) : pile résiduelle après login via Réglages --------------

  testWidgets(
      "M8 : Home → Settings → Login → login OK → Retour : pile [Home], "
      "pas de résidu", (tester) async {
    S.setLocale("fr");
    // Canal home_widget : refreshAfterLogin → _refreshWidget l'appelle ;
    // sans mock, le future de invokeMethod pend dans la zone fake-async.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel("home_widget"),
            (call) async => true);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      if (req.method == "POST" && req.url.path == "/auth/login") {
        return http.Response(
            jsonEncode({"access_token": "a", "refresh_token": "r"}), 200);
      }
      if (req.url.path == "/auth/me") {
        return http.Response(jsonEncode({"email": "m@x.fr"}), 200);
      }
      return http.Response("{}", 200);
    }));
    state.sync = _SpySync([]);

    late BuildContext appContext;
    final homePostKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
      home: Builder(
          builder: (c) {
            appContext = c;
            return const Center(child: Text("HOME-INIT"));
          }),
      routes: {
        "/settings": (_) => SettingsScreen(state: state),
        "/login": (_) => LoginScreen(state: state),
        // Le home POST-login remplace la route initiale (pushReplacement) :
        // le context capturé au-dessus est déssactivé → on récupère le
        // context du nouveau home via sa clé pour le Back.
        "/home": (_) => Center(child: Text("HOME-POST", key: homePostKey)),
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text("HOME-INIT"), findsOneWidget);

    Navigator.of(appContext).pushNamed("/settings");
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    Navigator.of(appContext).pushNamed("/login");
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), "m@x.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "LongPassw0rd!x");
    await tester.tap(find.text(S.login));
    await tester.pumpAndSettle();
    expect(find.text("HOME-POST"), findsOneWidget,
        reason: "M8 : on arrive sur Home");

    // Retour : avant le fix, la pile résiduelle [Home, Settings, Home]
    // ramenait sur Settings. canPop() == false : une seule route dans la
    // pile — le Back système (maybePop) ne ramène nulle part.
    final homePostContext = homePostKey.currentContext;
    expect(homePostContext, isNotNull);
    final nav = Navigator.of(homePostContext!);
    expect(nav.canPop(), false,
        reason: "M8 : pile [Home] seule — pas de résidu (Settings) derrière");
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing,
        reason: "M8 : le Back ne ramène pas sur Settings");
    expect(find.text("HOME-POST"), findsOneWidget);
    await state.db.close();
  });

  // ---- S2 : bouton « Se déconnecter » -----------------------------------

  testWidgets("S2 : logout → tokens purgés, route login, pas de sync",
      (tester) async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final paths = <String>[];
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      paths.add("${req.method} ${req.url.path}");
      if (req.url.path == "/auth/me") {
        return http.Response(jsonEncode({"email": "s@x.fr"}), 200);
      }
      if (req.url.path == "/auth/logout") return http.Response("", 204);
      return http.Response("{}", 200);
    }));
    state.api.accessToken = "tok";
    state.api.refreshTokenValue = "ref";
    state.sync = _SpySync(paths);

    // Vue haute : le ListView est paresseux — sans ça, la section « Compte »
    // (en bas) n'est pas construite et le bouton est introuvable.
    tester.view.physicalSize = const Size(720, 6000);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: SettingsScreen(state: state),
        routes: {"/login": (_) => LoginScreen(state: state)}));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Se déconnecter"));
    await tester.pumpAndSettle();

    expect(state.api.accessToken, isNull, reason: "S2 : tokens purgés");
    expect(state.api.refreshTokenValue, isNull);
    expect(
        paths.any((p) => p.contains("/sync")), isFalse,
        reason: "S2 : une déconnexion volontaire ne déclenche pas de sync");
    expect(paths, contains("POST /auth/logout"),
        reason: "S2 : l'endpoint de logout est appelé (révocation serveur)");
    expect(find.byType(LoginScreen), findsOneWidget,
        reason: "S2 : retour à l'écran de connexion");
    await state.db.close();
  });

  // ---- S3 : double-tap login → 1 seul appel API --------------------------

  testWidgets("S3 : double tap sur « Se connecter » → 1 seul POST login",
      (tester) async {
    S.setLocale("fr");
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var logins = 0;
    final state = AppState(db: AppDb.forTesting(NativeDatabase.memory()));
    state.api = ApiClient("https://srv",
        client: MockClient((req) async {
      if (req.method == "POST" && req.url.path == "/auth/login") {
        logins++;
        return http.Response(
            jsonEncode({"access_token": "a", "refresh_token": "r"}), 200);
      }
      if (req.url.path == "/auth/me") {
        return http.Response(jsonEncode({"email": "s3@x.fr"}), 200);
      }
      return http.Response("{}", 200);
    }));
    state.sync = _SpySync([]);

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: LoginScreen(state: state),
        routes: {"/home": (_) => const SizedBox()}));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), "s3@x.fr");
    await tester.enterText(find.byType(TextFormField).at(2), "LongPassw0rd!x");
    await tester.tap(find.text(S.login));
    await tester.tap(find.text(S.login)); // 2e tap avant la 1re résolution
    await tester.pumpAndSettle();

    expect(logins, 1,
        reason: "S3 : le double-tap ne doit pas lancer deux logins "
            "(avant fix : deux _auth() parallèles)");
    await state.db.close();
  });
}

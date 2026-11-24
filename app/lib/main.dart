import "dart:async";

import "package:flutter/foundation.dart"
    show defaultTargetPlatform, TargetPlatform;
import "package:http/http.dart" as http;
import "package:material_ui/material_ui.dart";
import "package:cupertino_ui/cupertino_ui.dart";
import "package:flutter_localizations/flutter_localizations.dart"
    hide GlobalMaterialLocalizations, GlobalCupertinoLocalizations;

import "data/android_updater.dart";
import "data/update_service.dart";
import "data/windows_updater.dart";
import "platform/tray_controller_web.dart"
    if (dart.library.io) "platform/tray_controller.dart";
import "ui/update_dialog.dart";
import "l10n/s.dart";
import "state/app_state.dart";
import "ui/home_screen.dart";
import "ui/list_screen.dart";
import "ui/login_screen.dart";
import "ui/settings_screen.dart";
import "ui/today_screen.dart";
import "ui/todo_all_screen.dart";

final appState = AppState();
TrayController? trayController;

// Routes nommées partagées par MaterialApp (test de régression
// red_screen_regression_test.dart importe ce map). "/home" est conservé :
// login_screen fait pushReplacementNamed("/home").
final appRoutes = <String, WidgetBuilder>{
  "/home": (_) => HomeScreen(state: appState),
  "/list": (_) => const ListScreenRoute(),
  "/login": (_) => LoginScreen(state: appState),
  "/settings": (_) => SettingsScreen(state: appState),
  "/today": (_) => TodayScreen(state: appState),
  "/todo": (_) => TodoAllScreen(state: appState),
};

/// Bannière persistante (audit lot T) : visible sur tous les écrans tant que
/// l'URL serveur est en http:// (connexion non chiffrée).
Widget appShell({required String serverUrl, required Widget child}) {
  if (!serverUrl.startsWith("http://")) return child;
  return Column(children: [
    // C2.2 : Material + SafeArea(top) — la bannière ne passe plus sous la
    // barre de statut Android.
    const Material(
        color: Colors.transparent,
        child: SafeArea(top: true, child: _InsecureServerBanner())),
    Expanded(child: child),
  ]);
}

class _InsecureServerBanner extends StatelessWidget {
  const _InsecureServerBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.orange.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(
          child: Text(S.insecureServer,
              style: const TextStyle(color: Colors.white),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await appState.init();
  // Spec §B + A2 : vérification des MAJ au démarrage — fond ; si une MAJ
  // est trouvée, le dialog est présenté par ChecklistsApp post-frame
  // (Windows + Android, comme le reste du flux update).
  unawaited(_checkUpdatesAtBoot());
  trayController = TrayController(appState);
  await trayController!.init();
  // Window hooks used by the flyout bridge (guarantee: opening the flyout
  // never hides the main window).
  appState.isMainWindowVisible = trayController!.isMainWindowVisible;
  appState.restoreMainWindow = trayController!.restoreMainWindow;
  runApp(const ChecklistsApp());
}

/// A2 : check de boot — le résultat est stocké dans [appState] ; le dialog
/// est présenté APRÈS la 1re frame (par ChecklistsApp), Windows + Android.
Future<void> _checkUpdatesAtBoot() async {
  final client = http.Client();
  try {
    final info = await checkForUpdates(client: client, api: appState.api);
    if (info.clientAvailable &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android)) {
      appState.setPendingBootUpdate(info);
    }
  } catch (_) {} finally {
    client.close();
  }
}

class ChecklistsApp extends StatefulWidget {
  const ChecklistsApp({super.key});

  @override
  State<ChecklistsApp> createState() => _ChecklistsAppState();
}

class _ChecklistsAppState extends State<ChecklistsApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    appState.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
    _maybeShowBootUpdate();
  }

  void _onChanged() {
    setState(() {});
    _maybeShowBootUpdate();
  }

  /// A2 : MAJ trouvée au boot → dialog post-frameCallback (jamais au milieu
  /// d'une frame). Gère les deux ordres : check terminé avant ou après la
  /// 1re frame.
  void _maybeShowBootUpdate() {
    final info = appState.pendingBootUpdate;
    if (info == null) return;
    appState.pendingBootUpdate = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => UpdateDialog(
          info: info,
          onUpdate: () async {
            // Même flux que la ligne « Mises à jour » des réglages.
            switch (defaultTargetPlatform) {
              case TargetPlatform.windows:
                await runSelfUpdate(info);
              case TargetPlatform.android:
                await installApk(info);
              default:
                break;
            }
          },
        ),
      );
    });
  }

  @override
  void dispose() {
    appState.removeListener(_onChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sync on every app resume (window focus, Android foreground) on top of
  /// the WebSocket push and the periodic poll.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Item coché dans le widget : l'activity singleTask est resumée, pas
      // re-créée → init() ne rejoue pas ; applyWidgetToggles() au resume
      // (idempotent via clearToggles).
      appState.applyWidgetToggles();
      appState.sync.fullSync();
    }
  }

  ThemeMode get _themeMode {
    switch (appState.settings["theme"]) {
      case "light":
        return ThemeMode.light;
      case "dark":
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = appState.settings["lang"] as String? ?? "fr";
    return MaterialApp(
      title: "Tapitask",
      debugShowCheckedModeBanner: false,
      // Material widgets (date/time pickers, dialogs) follow the synced
      // per-user language, like every Tapitask string (S.*).
      locale: Locale(lang),
      supportedLocales: const [Locale("fr"), Locale("en")],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      // Bannière http:// persistante au-dessus de TOUS les écrans (lot T).
      builder: (context, child) => appShell(
          serverUrl: appState.api.baseUrl,
          child: child ?? const SizedBox.shrink()),
      // home: au lieu de initialRoute — le fallback "/" du moteur résout
      // toujours, quelle que soit l'initial route envoyée (launcher "/",
      // widget "tapitask://home" / "tapitask://quickadd/<id>").
      home: HomeScreen(state: appState),
      routes: appRoutes,
    );
  }
}

class ListScreenRoute extends StatelessWidget {
  const ListScreenRoute({super.key});

  @override
  Widget build(BuildContext context) {
    final listId = ModalRoute.of(context)?.settings.arguments as String;
    return ListScreen(state: appState, listId: listId);
  }
}

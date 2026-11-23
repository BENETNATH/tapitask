import "dart:async";

import "package:http/http.dart" as http;
import "package:material_ui/material_ui.dart";
import "package:cupertino_ui/cupertino_ui.dart";
import "package:flutter_localizations/flutter_localizations.dart"
    hide GlobalMaterialLocalizations, GlobalCupertinoLocalizations;

import "data/update_service.dart";
import "platform/tray_controller_web.dart"
    if (dart.library.io) "platform/tray_controller.dart";
import "state/app_state.dart";
import "ui/calendar_screen.dart";
import "ui/home_screen.dart";
import "ui/list_screen.dart";
import "ui/login_screen.dart";
import "ui/settings_screen.dart";
import "ui/today_screen.dart";
import "ui/todo_all_screen.dart";
import "ui/task_details.dart";

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
  "/calendar": (_) => CalendarScreen(state: appState),
  "/todo": (_) => TodoAllScreen(state: appState),
};

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await appState.init();
  // Spec §B : vérification des MAJ au démarrage — fond, sans UI bloquante
  // (résultat consulté depuis la ligne « Mises à jour » des réglages).
  unawaited(() async {
    final client = http.Client();
    try {
      await checkForUpdates(client: client, api: appState.api);
    } finally {
      client.close();
    }
  }());
  trayController = TrayController(appState);
  await trayController!.init();
  // Window hooks used by the flyout bridge (guarantee: opening the flyout
  // never hides the main window).
  appState.isMainWindowVisible = trayController!.isMainWindowVisible;
  appState.restoreMainWindow = trayController!.restoreMainWindow;
  runApp(const ChecklistsApp());
}

class ChecklistsApp extends StatefulWidget {
  const ChecklistsApp({super.key});

  @override
  State<ChecklistsApp> createState() => _ChecklistsAppState();
}

class _ChecklistsAppState extends State<ChecklistsApp>
    with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    appState.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
    _openRequestedTask();
  }

  void _onChanged() {
    setState(() {});
    _openRequestedTask();
  }

  void _openRequestedTask() {
    if (appState.requestedTask == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final task = appState.requestedTask;
      final context = _navigator.currentContext;
      if (!mounted || task == null || context == null) return;
      appState.requestedTask = null;
      unawaited(showTaskDetails(context, appState, task));
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
      navigatorKey: _navigator,
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

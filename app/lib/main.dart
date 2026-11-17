import "package:material_ui/material_ui.dart";
import "package:cupertino_ui/cupertino_ui.dart";
import "package:flutter_localizations/flutter_localizations.dart"
    hide GlobalMaterialLocalizations, GlobalCupertinoLocalizations;

import "platform/tray_controller.dart";
import "state/app_state.dart";
import "ui/home_screen.dart";
import "ui/list_screen.dart";
import "ui/login_screen.dart";
import "ui/settings_screen.dart";
import "ui/today_screen.dart";
import "ui/todo_all_screen.dart";

final appState = AppState();
TrayController? trayController;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await appState.init();
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
  @override
  void initState() {
    super.initState();
    appState.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onChanged() => setState(() {});

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
      initialRoute: "/home",
      routes: {
        "/home": (_) => HomeScreen(state: appState),
        "/list": (_) => const ListScreenRoute(),
        "/login": (_) => LoginScreen(state: appState),
        "/settings": (_) => SettingsScreen(state: appState),
        "/today": (_) => TodayScreen(state: appState),
        "/todo": (_) => TodoAllScreen(state: appState),
      },
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

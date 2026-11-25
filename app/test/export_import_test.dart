import "dart:convert";

import "package:drift/drift.dart" hide isNull;
import "package:drift/native.dart";
import "package:file_selector/file_selector.dart" show XFile;
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/l10n/s.dart";
import "package:tapitask/platform/file_service.dart";
import "package:tapitask/state/app_state.dart";
import "package:tapitask/ui/list_screen.dart";
import "package:tapitask/ui/settings_screen.dart";

/// D-7 (spec 2026-11-25) : menu « Exporter » (JSON/Markdown/CSV) +
/// « Importer » dans la list_screen ; export global + import dans les
/// réglages. Les dialogs et l'I/O de fichiers sont injectés
/// (seams `pickFileForTesting`/`saveForTesting`) — l'I/O dart:io ne
/// complète pas dans la zone factice des widget tests ; l'API est un
/// espion qui enregistre les appels.

/// ApiClient espion : enregistre les appels, renvoie un corps fixe.
class _SpyApi extends ApiClient {
  _SpyApi() : super("http://api.test");

  final calls = <String>[];
  final rawBody = '{"tapitask":1,"exported_at":"2026-11-25","lists":[]}';
  Object? importError;
  Map<String, dynamic> importResult = {
    "lists": [
      {"id": "1", "title": "T", "items": 1}
    ]
  };

  @override
  Future<String> getRaw(String path, {bool retried = false}) async {
    calls.add("GET $path");
    return rawBody;
  }

  @override
  Future<Map<String, dynamic>> importFile(String body, {String? name}) async {
    calls.add("POST /import (name=$name, ${body.length} octets)");
    if (importError != null) throw importError!;
    return importResult;
  }
}

XFile _pickedFile(String name, String body) =>
    XFile.fromData(Uint8List.fromList(utf8.encode(body)), path: "/tmp/$name");

/// Fait défiler la file des snackbars (ScaffoldMessenger est séquentiel)
/// pour qu'un snackbar suivant s'affiche sans attendre le précédent.
Future<void> _dismissSnackbars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  Future<AppState> listState(AppDb db, _SpyApi spy) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await db.upsertList(LocalListsCompanion(
      id: const Value("lst1"),
      title: const Value("Courses"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(true),
    ));
    return AppState(db: db)..api = spy;
  }

  testWidgets("le menu de la liste a Exporter (JSON/MD/CSV) + Importer",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final spy = _SpyApi();
    final state = await listState(db, spy);
    addTearDown(spy.close);
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: "lst1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();

    expect(find.text(S.exportJson), findsOneWidget);
    expect(find.text(S.exportMarkdown), findsOneWidget);
    expect(find.text(S.exportCsv), findsOneWidget);
    expect(find.text(S.importFile), findsOneWidget);
    await db.close();
  });

  testWidgets("export JSON : GET /lists/{id}/export.json + sauvegarde + snackbar",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final spy = _SpyApi();
    final state = await listState(db, spy);
    addTearDown(spy.close);
    final saved = <(String, String)>[];
    addTearDown(resetFileSeamsForTesting);
    saveForTesting = (content, name) async {
      saved.add((name, content));
      return true;
    };
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: "lst1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.exportJson));
    await tester.pumpAndSettle();

    expect(spy.calls, contains("GET /lists/lst1/export.json"));
    expect(saved, [("courses.json", spy.rawBody)],
        reason: "le corps de l'export est sauvé tel quel sous <slug>.json");
    expect(find.text(S.exportedOk), findsOneWidget);
    await db.close();
  });

  for (final (label, path) in [
    (S.exportMarkdown, "/lists/lst1/export.md"),
    (S.exportCsv, "/lists/lst1/export.csv"),
  ]) {
    testWidgets("export $label : GET $path + sauvegarde + snackbar",
        (tester) async {
      final db = AppDb.forTesting(NativeDatabase.memory());
      final spy = _SpyApi();
      final state = await listState(db, spy);
      addTearDown(spy.close);
      final saved = <(String, String)>[];
      addTearDown(resetFileSeamsForTesting);
      saveForTesting = (content, name) async {
        saved.add((name, content));
        return true;
      };
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;

      await tester.pumpWidget(MaterialApp(
          localizationsDelegates:
              const [GlobalMaterialLocalizations.delegate],
          home: ListScreen(state: state, listId: "lst1")));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();

      expect(spy.calls, contains("GET $path"));
      expect(saved.single.$1,
          label == S.exportMarkdown ? "courses.md" : "courses.csv");
      expect(saved.single.$2, spy.rawBody);
      expect(find.text(S.exportedOk), findsOneWidget);
      await db.close();
    });
  }

  testWidgets("import réussi : pick → POST /import (name) + snackbar",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final spy = _SpyApi();
    final state = await listState(db, spy);
    addTearDown(spy.close);
    final body = "# Ma Liste\n- [ ] un item\n";
    addTearDown(resetFileSeamsForTesting);
    pickFileForTesting = () async => _pickedFile("ma-liste.md", body);
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: "lst1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.importFile));
    await tester.pumpAndSettle();

    expect(spy.calls,
        contains("POST /import (name=ma-liste.md, ${body.length} octets)"),
        reason: "le corps du fichier est POSTé, name = nom du fichier");
    expect(find.text(S.importedOk), findsOneWidget);
    await db.close();
  });

  testWidgets("import en échec : snackbar d'échec (pas de crash)",
      (tester) async {
    final db = AppDb.forTesting(NativeDatabase.memory());
    final spy = _SpyApi()
      ..importError = ApiException(400, "Invalid import format");
    final state = await listState(db, spy);
    addTearDown(spy.close);
    addTearDown(resetFileSeamsForTesting);
    pickFileForTesting =
        () async => _pickedFile("corps.txt", "ceci n'est pas importable");
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;

    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: ListScreen(state: state, listId: "lst1")));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.importFile));
    await tester.pumpAndSettle();

    expect(find.text(S.importFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
    await db.close();
  });

  testWidgets("réglages : export global JSON/CSV + import câblés",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDb.forTesting(NativeDatabase.memory());
    final spy = _SpyApi();
    final state = AppState(db: db)..api = spy;
    addTearDown(spy.close);
    final saved = <(String, String)>[];
    addTearDown(resetFileSeamsForTesting);
    saveForTesting = (content, name) async {
      saved.add((name, content));
      return true;
    };
    final importBody = '{"tapitask":1,"lists":[]}';
    pickFileForTesting = () async => _pickedFile("import.json", importBody);

    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate],
        home: SettingsScreen(state: state)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text(S.exportAllJson), 200);
    await tester.tap(find.text(S.exportAllJson));
    await tester.pumpAndSettle();
    expect(spy.calls, contains("GET /export.json?scope=all"));
    expect(saved[0], ("tapitask-all.json", spy.rawBody));
    await _dismissSnackbars(tester);

    await tester.tap(find.text(S.exportAllCsv));
    await tester.pumpAndSettle();
    expect(spy.calls, contains("GET /export.csv?scope=all"));
    expect(saved[1].$1, "tapitask-all.csv");
    await _dismissSnackbars(tester);

    await tester.scrollUntilVisible(find.text(S.importFile), 200);
    await tester.tap(find.text(S.importFile));
    await tester.pumpAndSettle();
    expect(spy.calls,
        contains("POST /import (name=import.json, ${importBody.length} octets)"));
    expect(find.text(S.importedOk), findsOneWidget);
    await db.close();
  });
}

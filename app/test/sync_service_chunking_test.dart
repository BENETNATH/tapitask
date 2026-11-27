// Spec 2026-11-27 — SyncService : chunking du push /sync (max 500 events
// par POST). Pathway publique : items dirty dans la base → fullSync() →
// _pushOutbox → _postEvents (mêmes patterns que test/audit_c1c2_test.dart).
import "dart:convert";
import "dart:io";

import "package:drift/drift.dart";
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/sync_service.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      "chunking : 1200 events dirty → 3 POST /sync (500/500/200), pas 1 seul",
      () async {
    SharedPreferences.setMockInitialValues({});
    final chunks = <List<dynamic>>[];
    final api = ApiClient("https://srv", client: MockClient((request) async {
      if (request.url.path == "/sync" && request.method == "POST") {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        // Le PULL POST /sync n'a pas de clé « events » dans son body :
        // on ne compte que les chunks du push.
        if (body.containsKey("events")) {
          chunks.add(body["events"] as List<dynamic>);
        }
        return http.Response(
            jsonEncode({"rejected": <String>[], "changes": <Object>[]}), 200);
      }
      return http.Response("not found", 404);
    }));
    api.accessToken = "a";
    final db = AppDb.forTesting(NativeDatabase.memory());
    await db.upsertList(LocalListsCompanion(
      id: const Value("l1"),
      title: const Value("L"),
      ownerId: const Value(""),
      updatedAt: Value(DateTime.now().toUtc()),
      dirty: const Value(false),
      localOnly: const Value(false),
    ));
    final now = DateTime.now().toUtc();
    for (var i = 0; i < 1200; i++) {
      await db.addItem("item-$i", "l1", "item $i", i, now);
    }

    final sync = SyncService(api: api, db: db);
    await sync.fullSync();
    sync.dispose();
    await db.close();

    expect(chunks.length, 3,
        reason: "1200 events chunkés à 500 → ceil(1200/500) = 3 POST, "
            "pas 1 seul avec tout dedans");
    expect(chunks.map((c) => c.length).toList(), [500, 500, 200],
        reason: "les deux premiers chunks sont pleins, le 3e au reste");
  });

  test("backoff : échec WS permanent → délai de reconnexion CROISSANT, "
      "pas constant (spec 2026-11-27-sync-backoff-fix)", () async {
    // Serveur loopback qui REFUSE l'upgrade WebSocket (404, pas de 101) :
    // `ready` complète en erreur à CHAQUE tentative — seul mode où le
    // compteur d'échecs doit persister. Une requête reçue = une tentative
    // de connexion. (Pattern du serveur local de test/audit_prod3_test
    // 1.4d, en mode échec.)
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final attempts = <DateTime>[];
    server.listen((request) async {
      attempts.add(DateTime.now());
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final api = ApiClient("http://127.0.0.1:${server.port}");
    api.accessToken = "a";
    final db = AppDb.forTesting(NativeDatabase.memory());
    final sync = SyncService(api: api, db: db);
    await sync.listenRealtime(); // tentative 1 (échoue → reconnexion timer)
    // Les tentatives suivantes sortent du timer interne _scheduleReconnect :
    // ≈4 s puis ≈8 s après le fix (2 << 1 puis 2 << 2). Attendre ~16 s
    // pour capter les 3 premières tentatives (tolérance large : c'est la
    // PROGRESSION du délai qui est vérifiée, pas la valeur exacte).
    await Future<void>.delayed(const Duration(seconds: 16));
    sync.dispose();
    await server.close(force: true);
    await db.close();

    expect(attempts.length, greaterThanOrEqualTo(3),
        reason: "au moins 3 tentatives de connexion captees");
    final d1 = attempts[1].difference(attempts[0]);
    final d2 = attempts[2].difference(attempts[1]);
    expect(d2, greaterThan(d1 + const Duration(seconds: 2)),
        reason: "le backoff doit progresser (≈4 s puis ≈8 s) ; un délai "
            "constant à ≈4 s à chaque fois signale le reset intempestif "
            "du compteur d'échecs avant confirmation de connexion");
  });
}

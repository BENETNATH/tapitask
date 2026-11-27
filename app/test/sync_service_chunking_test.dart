// Spec 2026-11-27 — SyncService : chunking du push /sync (max 500 events
// par POST). Pathway publique : items dirty dans la base → fullSync() →
// _pushOutbox → _postEvents (mêmes patterns que test/audit_c1c2_test.dart).
import "dart:convert";

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
}

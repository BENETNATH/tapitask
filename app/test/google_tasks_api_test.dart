import "dart:convert";

import "package:drift/drift.dart" show Value;
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:tapitask/data/database.dart";
import "package:tapitask/data/google_tasks_api.dart";
import "package:tapitask/l10n/s.dart";

final _task = LocalItem(
  id: "task",
  listId: "tapitask-list",
  label: "Préparer le dîner",
  notes: "Acheter du riz 🍚",
  dueDate: DateTime(2026, 11, 23, 0, 5),
  updatedAt: DateTime(2026, 11, 22),
  done: true,
  position: 0,
  recurrence: "weekly",
  deleted: false,
  dirty: false,
);

void main() {
  setUp(() => S.setLocale("en"));

  test("imports completed tasks, calendar dates, notes and links across pages",
      () async {
    final client = MockClient((request) async {
      expect(request.url.path, "/tasks/v1/lists/inbox/tasks");
      expect(request.url.queryParameters["showCompleted"], "true");
      expect(request.url.queryParameters["showHidden"], "true");
      final first = request.url.queryParameters["pageToken"] == null;
      return http.Response(
          jsonEncode(first
              ? {
                  "nextPageToken": "next",
                  "items": [
                    {
                      "id": "parent",
                      "title": "Parent",
                      "status": "completed",
                      "completed": "2026-11-22T13:30:00.000Z",
                      "due": "2026-11-23T00:00:00.000Z",
                      "notes": "Extra text",
                      "links": [
                        {"link": "https://example.com/task"}
                      ]
                    }
                  ],
                }
              : {
                  "items": [
                    {"id": "child", "title": "Child", "parent": "parent"},
                    {"id": "deleted", "deleted": true}
                  ],
                }),
          200);
    });
    addTearDown(client.close);

    final tasks = await GoogleTasksApi(client, "token").tasks("inbox");
    expect(tasks.map((t) => t.id), ["parent", "child"]);
    expect(tasks.first.dueDay, "2026-11-23");
    expect(tasks.first.done, isTrue);
    expect(tasks.first.completedAt, DateTime.utc(2026, 11, 22, 13, 30));
    expect(tasks.first.notes, "Extra text\nhttps://example.com/task");
    expect(tasks.last.parent, "parent");
  });
  test("reads all pages of Google lists and decodes UTF-8 titles", () async {
    final pageTokens = <String?>[];
    final client = MockClient((request) async {
      expect(request.url.host, "tasks.googleapis.com");
      expect(request.url.path, "/tasks/v1/users/@me/lists");
      expect(request.headers["authorization"], "Bearer token");
      final page = request.url.queryParameters["pageToken"];
      pageTokens.add(page);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          "items": [
            if (page == null)
              {"id": "home", "title": "À la maison"}
            else
              {"id": "work", "title": "Travail"},
          ],
          if (page == null) "nextPageToken": "page+2=",
        })),
        200,
      );
    });
    addTearDown(client.close);

    final api = GoogleTasksApi(client, "token");
    expect(await api.lists(), [
      (id: "home", title: "À la maison"),
      (id: "work", title: "Travail"),
    ]);
    expect(pageTokens, [null, "page+2="]);
  });

  test("adds the local time to existing notes and sends the calendar day",
      () async {
    final client = MockClient((request) async {
      expect(request.method, "POST");
      expect(
          request.url.pathSegments, ["tasks", "v1", "lists", "a/b", "tasks"]);
      expect(request.headers["authorization"], "Bearer token");
      expect(jsonDecode(utf8.decode(request.bodyBytes)), {
        "title": "Préparer le dîner",
        "notes": "Acheter du riz 🍚\n\nTime in Tapitask · 00:05",
        "due": "2026-11-23T00:00:00.000Z",
        "status": "completed",
      });
      return http.Response('{}', 201);
    });
    addTearDown(client.close);
    await GoogleTasksApi(client, "token").createTask("a/b", _task);
  });

  test("includes an explicit midnight and leaves all-day notes alone",
      () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('{}', 201);
    });
    addTearDown(client.close);
    final api = GoogleTasksApi(client, "token");

    await api.createTask(
        "list",
        _task.copyWith(
            notes: const Value(null), dueDate: Value(DateTime(2026, 11, 23))));
    await api.createTask(
        "list", _task.copyWith(dueDay: const Value("2026-11-23")));

    expect(bodies.first["notes"], "Time in Tapitask · 00:00");
    expect(bodies.last["notes"], _task.notes);
    expect(bodies.map((body) => body["due"]),
        everyElement("2026-11-23T00:00:00.000Z"));
  });

  test("preserves notes that already fill Google's limit", () async {
    final notes = "a" * 8192;
    final client = MockClient((request) async {
      expect((jsonDecode(request.body) as Map)["notes"], notes);
      return http.Response('{}', 201);
    });
    addTearDown(client.close);
    await GoogleTasksApi(client, "token")
        .createTask("list", _task.copyWith(notes: Value(notes)));
  });

  test("reports an uncertain creation without retrying a dropped connection",
      () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw http.ClientException("Disconnected");
    });
    addTearDown(client.close);
    await expectLater(
      GoogleTasksApi(client, "token").createTask("list", _task),
      throwsA(isA<GoogleTasksRequestFailed>()
          .having((error) => error.writeUncertain, "uncertain", true)),
    );
    expect(attempts, 1);
  });
}

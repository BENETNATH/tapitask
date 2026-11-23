import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../l10n/s.dart";
import "database.dart";
import "task_links.dart";

typedef GoogleTaskList = ({String id, String title});
typedef GoogleTask = ({
  String id,
  String title,
  String? notes,
  String? dueDay,
  String? parent,
  bool done,
  DateTime? completedAt
});

class GoogleTasksApi {
  GoogleTasksApi(this._client, this._accessToken);

  static const _host = "tasks.googleapis.com";
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;
  final String _accessToken;

  Map<String, String> get _headers => {
        "Authorization": "Bearer $_accessToken",
        "Content-Type": "application/json; charset=utf-8",
      };

  Future<List<GoogleTaskList>> lists() async {
    final lists = <GoogleTaskList>[];
    await for (final item in _readPages(
        ["tasks", "v1", "users", "@me", "lists"], {"maxResults": "1000"})) {
      if (item case {"id": final String id, "title": final String title}) {
        lists.add((id: id, title: title));
      } else {
        throw const FormatException();
      }
    }
    return lists;
  }

  Future<List<GoogleTask>> tasks(String listId) async {
    final tasks = <GoogleTask>[];
    await for (final item in _readPages([
      "tasks",
      "v1",
      "lists",
      listId,
      "tasks"
    ], {
      "maxResults": "100",
      "showCompleted": "true",
      "showHidden": "true",
    })) {
      if (item["deleted"] == true) continue;
      if (item case {"id": final String id, "title": final String title}) {
        final notes = item["notes"] as String?;
        final links = taskLinks(notes ?? "").toSet();
        final extra = <String>[];
        for (final entry in (item["links"] as List? ?? [])) {
          if (entry case {"link": final String value}) {
            final url = taskLink(value);
            if (url != null && links.add(url)) extra.add(url.toString());
          }
        }
        final text =
            [if (notes?.isNotEmpty == true) notes!, ...extra].join("\n");
        final due = item["due"] as String?;
        // Google serializes a calendar day in a timestamp. Read its date
        // components directly so the timezone cannot move it to another day.
        final day = due?.split("T").first;
        tasks.add((
          id: id,
          title: title,
          notes: text.isEmpty ? null : text,
          dueDay: day,
          parent: item["parent"] as String?,
          done: item["status"] == "completed",
          completedAt: DateTime.tryParse(item["completed"] as String? ?? ""),
        ));
      } else {
        throw const FormatException();
      }
    }
    return tasks;
  }

  Stream<Map<String, dynamic>> _readPages(
      List<String> path, Map<String, String> query) async* {
    String? pageToken;
    final seenTokens = <String>{};
    do {
      final response = await _client
          .get(
            Uri(
                scheme: "https",
                host: _host,
                pathSegments: path,
                queryParameters: {
                  ...query,
                  if (pageToken != null) "pageToken": pageToken,
                }),
            headers: _headers,
          )
          .timeout(_timeout);
      if (response.statusCode != 200) throw const GoogleTasksRequestFailed();

      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) throw const FormatException();
      final items = body["items"] ?? [];
      if (items is! List) throw const FormatException();
      for (final item in items) {
        if (item is! Map<String, dynamic>) throw const FormatException();
        yield item;
      }
      final nextPageToken = body["nextPageToken"];
      if (nextPageToken != null && nextPageToken is! String) {
        throw const FormatException();
      }
      pageToken = nextPageToken as String?;
      if (pageToken != null && !seenTokens.add(pageToken)) {
        throw const FormatException();
      }
    } while (pageToken != null && pageToken.isNotEmpty);
  }

  Future<void> createTask(String listId, LocalItem task) async {
    final due = task.localDue;
    final notes = _exportNotes(task, due);
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri(
              scheme: "https",
              host: _host,
              pathSegments: ["tasks", "v1", "lists", listId, "tasks"],
            ),
            headers: _headers,
            body: jsonEncode({
              "title": task.label,
              if (notes.isNotEmpty) "notes": notes,
              "status": task.done ? "completed" : "needsAction",
              if (due != null)
                // Google Tasks only accepts a calendar date, so write the
                // local day at UTC midnight without shifting the day.
                "due": DateTime.utc(due.year, due.month, due.day)
                    .toIso8601String(),
            }),
          )
          .timeout(_timeout);
    } on http.ClientException {
      throw const GoogleTasksRequestFailed(writeUncertain: true);
    } on TimeoutException {
      throw const GoogleTasksRequestFailed(writeUncertain: true);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GoogleTasksRequestFailed(
          writeUncertain:
              response.statusCode >= 500 || response.statusCode == 408);
    }
  }

  String _exportNotes(LocalItem task, DateTime? due) {
    final notes = task.notes ?? "";
    if (task.dueDay != null || due == null) return notes;

    final hour = due.hour.toString().padLeft(2, "0");
    final minute = due.minute.toString().padLeft(2, "0");
    final time = "${S.googleTasksTimeNote} · $hour:$minute";
    final combined = notes.isEmpty ? time : "$notes\n\n$time";
    // Keep an existing export valid when its notes already fill Google's field.
    return combined.length <= 8192 ? combined : notes;
  }
}

class GoogleTasksRequestFailed implements Exception {
  const GoogleTasksRequestFailed({this.writeUncertain = false});

  final bool writeUncertain;
}

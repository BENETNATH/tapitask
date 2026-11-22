import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:tapitask/data/api_client.dart";
import "package:tapitask/data/update_service.dart";

/// Client http factice : aucun appel réseau réel, aucune requête GitHub.
class FakeHttpClient implements http.Client {
  final Map<String, (int, String)> routes;
  FakeHttpClient(this.routes);

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final r = routes[url.toString()];
    if (r == null) return http.Response("not found", 404);
    return http.Response(r.$2, r.$1, headers: {"content-type": "application/json"});
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError("non utilisé : ${invocation.memberName}");
}

final githubUrl = "https://api.github.com/repos/BENETNATH/tapitask/releases/latest";

String githubPayload({String tag = "v0.4.0", String body = "notes v0.4.0"}) =>
    jsonEncode({
      "tag_name": tag,
      "name": tag,
      "body": body,
      "assets": [
        {
          "name": "tapitask-$tag-windows-x64.zip",
          "browser_download_url": "https://gh.io/tapitask-$tag-windows-x64.zip",
        },
        {
          "name": "tapitask-$tag-android.apk",
          "browser_download_url": "https://gh.io/tapitask-$tag-android.apk",
        },
        // Artefact parasite : ne doit ni être choisi ni casser le parsing.
        {
          "name": "tapitask-$tag.dmg",
          "browser_download_url": "https://gh.io/tapitask-$tag.dmg",
        },
      ],
    });

FakeHttpClient clientFor({
  int githubStatus = 200,
  String githubBody = "ok",
  int serverStatus = 200,
  String serverVersion = "0.3.0",
}) =>
    FakeHttpClient({
      githubUrl: (
        githubStatus,
        githubStatus == 200
            ? githubBody
            : jsonEncode({"message": "rate limit exceeded"}),
      ),
      "https://api.example.com/version": (
        serverStatus,
        jsonEncode({"version": serverVersion}),
      ),
    });

ApiClient api() => ApiClient("https://api.example.com");

void main() {
  test("R-B4 : payload GitHub réel — urls par motif de nom, notes parsées",
      () async {
    final c = clientFor(githubBody: githubPayload(body: "nouvelles features"));
    final info = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.3.0");
    expect(info.latest, "0.4.0");
    expect(info.clientCurrent, "0.3.0");
    expect(info.windowsUrl, "https://gh.io/tapitask-v0.4.0-windows-x64.zip",
        reason: "asset Windows sélectionné par motif *-windows-x64.zip");
    expect(info.apkUrl, "https://gh.io/tapitask-v0.4.0-android.apk",
        reason: "asset APK sélectionné par motif *-android.apk");
    expect(info.notes, "nouvelles features");
  });

  test("R-B4 : notes markdown — les marqueurs gras/code sont retirés",
      () async {
    final c = clientFor(
        githubBody: githubPayload(
            body: "- **Sync par lots** : un `savepoint` par événement"));
    final info = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.3.0");
    expect(info.notes, "- Sync par lots : un savepoint par événement",
        reason: "pas de ** ni de ` dans le texte affiché");
  });

  test("R-B4 : 0.3.0 → 0.4.0 dispo ; 0.4.0 → 0.4.0 non dispo", () async {
    final c = clientFor(githubBody: githubPayload());
    final up = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.3.0");
    expect(up.clientAvailable, isTrue);
    final same = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.4.0");
    expect(same.clientAvailable, isFalse);
  });

  test("R-B4 : 0.3.10 > 0.3.9 (piège lexicographique)", () async {
    final c = clientFor(
        githubBody: githubPayload(tag: "v0.3.10", body: "patch"));
    final info = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.3.9");
    expect(info.clientAvailable, isTrue,
        reason: "comparaison sur le tuple numérique, pas lexicographique");
  });

  test("R-B4 : serveur 0.2.0 vs latest 0.3.0 → serverRequired, notes préservées",
      () async {
    final c = clientFor(
        githubBody: githubPayload(tag: "v0.3.0", body: "fixes serveur"),
        serverVersion: "0.2.0");
    final info = await checkForUpdates(
        client: c, api: api(), clientVersion: "0.3.0");
    expect(info.serverRequired, isTrue);
    expect(info.serverVersion, "0.2.0");
    expect(info.clientAvailable, isFalse, reason: "client à jour");
    expect(info.notes, "fixes serveur", reason: "notes préservées");
  });

  test("R-B4 : GitHub 403 (rate limit) → neutre, serveur toujours évalué",
      () async {
    final c = clientFor(githubStatus: 403, serverVersion: "0.2.0");
    final info =
        await checkForUpdates(client: c, api: api(), clientVersion: "0.3.0");
    expect(info.clientAvailable, isFalse);
    expect(info.latest, isEmpty, reason: "neutre : aucune version connue");
    expect(info.windowsUrl, isNull);
    expect(info.apkUrl, isNull);
    expect(info.serverRequired, isFalse);
    expect(info.serverVersion, "0.2.0",
        reason: "la version serveur est toujours évaluée");
  });

  test("R-B4 : échec version serveur ne masque pas la partie GitHub", () async {
    final c = clientFor(serverStatus: 500, githubBody: githubPayload());
    final info =
        await checkForUpdates(client: c, api: api(), clientVersion: "0.3.0");
    expect(info.clientAvailable, isTrue);
    expect(info.windowsUrl, isNotNull);
    expect(info.apkUrl, isNotNull);
    expect(info.serverVersion, isNull);
    expect(info.serverRequired, isFalse);
  });
}

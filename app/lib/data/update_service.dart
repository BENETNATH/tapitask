import "dart:convert";

import "package:http/http.dart" as http;

import "api_client.dart";
import "app_version.dart";

/// Résultat d'une vérification de mise à jour.
/// `latest` = "" quand GitHub n'a pas répondu (neutre : aucune version
/// connue, ni MAJ client ni exigence serveur).
class UpdateInfo {
  final bool clientAvailable;
  final String latest;
  final String clientCurrent;
  final String notes;
  final String? windowsUrl;
  final String? apkUrl;
  final bool serverRequired;
  final String? serverVersion;
  const UpdateInfo({
    required this.clientAvailable,
    required this.latest,
    required this.clientCurrent,
    this.notes = "",
    this.windowsUrl,
    this.apkUrl,
    required this.serverRequired,
    this.serverVersion,
  });
}

const kLatestReleaseUrl =
    "https://api.github.com/repos/BENETNATH/tapitask/releases/latest";
const kReleasePageUrl =
    "https://github.com/BENETNATH/tapitask/releases/latest";

/// Semver minimale sans dépendance : préfixe `v` toléré, tuple numérique
/// (`0.3.10 > 0.3.9` — pas de comparaison lexicographique). null si non
/// parsable (ex. 'dev', 'unknown').
List<int>? parseSemver(String s) {
  s = s.trim();
  if (s.startsWith("v")) s = s.substring(1);
  final parts = s.split(".");
  if (parts.length > 3) return null;
  final out = <int>[];
  for (final p in parts) {
    final v = int.tryParse(p);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// true si `latest` > `current` (les deux non-parsables → false).
bool isNewer(String latest, String current) {
  final a = parseSemver(latest);
  final b = parseSemver(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Les notes de release sont du markdown GitHub : on retire les marqueurs
/// gras/code pour que le dialog les affiche en texte brut.
String _plainNotes(String s) => s.replaceAll(RegExp(r"\*{1,2}|`"), "");

/// Vérifie les MAJ (fond, sans UI bloquante) :
/// 1. `GET {baseUrl}/version` → version serveur (échec isolé, ne masque pas
///    la partie GitHub) ;
/// 2. `GET .../releases/latest` → tag_name, body (notes), assets par motif
///    de nom (`*-windows-x64.zip`, `*-android.apk`).
/// Échec réseau / 403 GitHub (rate limit) → [UpdateInfo] neutre.
Future<UpdateInfo> checkForUpdates({
  required http.Client client,
  required ApiClient api,
  String? clientVersion,
  // 2.5 (prod3) : timeout — sans, un réseau mort fait tourner le check
  // indéfiniment (le boot attendait).
  Duration checkTimeout = const Duration(seconds: 30),
}) async {
  final current = clientVersion ?? appVersion;

  String? serverVersion;
  if (api.isConfigured) {
    try {
      final r = await client
          .get(Uri.parse("${api.baseUrl}/version"))
          .timeout(checkTimeout);
      if (r.statusCode == 200) {
        final v = (jsonDecode(r.body) as Map<String, dynamic>)["version"];
        if (v is String && v.trim().isNotEmpty) {
          serverVersion = v.trim();
        }
      }
    } catch (_) {}
  }

  UpdateInfo neutral() => UpdateInfo(
        clientAvailable: false,
        latest: "",
        clientCurrent: current,
        serverRequired: false,
        serverVersion: serverVersion,
      );

  try {
    final r = await client.get(Uri.parse(kLatestReleaseUrl)).timeout(checkTimeout);
    if (r.statusCode != 200) return neutral();
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    var latest = (data["tag_name"] as String? ?? "").trim();
    if (latest.startsWith("v")) {
      latest = latest.substring(1);
    }
    String? windowsUrl;
    String? apkUrl;
    final assets = data["assets"];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = a["name"] as String? ?? "";
        final url = a["browser_download_url"] as String? ?? "";
        // 2.5 (prod3) : seuls les assets https sont retenus — le
        // téléchargement (updaters) refuse tout autre schéma.
        if (name.endsWith("-windows-x64.zip") && url.startsWith("https://")) {
          windowsUrl = url;
        } else if (name.endsWith("-android.apk") &&
            url.startsWith("https://")) {
          apkUrl = url;
        }
      }
    }
    return UpdateInfo(
      clientAvailable: isNewer(latest, current),
      latest: latest,
      clientCurrent: current,
      notes: _plainNotes((data["body"] as String? ?? "").trim()),
      windowsUrl: windowsUrl,
      apkUrl: apkUrl,
      serverRequired:
          serverVersion != null && isNewer(latest, serverVersion),
      serverVersion: serverVersion,
    );
  } catch (_) {
    return neutral();
  }
}

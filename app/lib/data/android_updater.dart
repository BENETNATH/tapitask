import "dart:io";

import "package:flutter/services.dart";
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "update_service.dart";

/// Mise à jour Android (spec §B.6) : téléchargement de l'APK dans le cache
/// de l'app, puis le package installer système est lancé via le
/// MethodChannel (MainActivity.kt : FileProvider + ACTION_VIEW +
/// FLAG_GRANT_READ_URI_PERMISSION ; permission REQUEST_INSTALL_PACKAGES).
const _updaterChannel = MethodChannel("com.tapitask/tapitask/updater");

Future<void> installApk(UpdateInfo info) async {
  final apkUrl = info.apkUrl;
  if (apkUrl == null) {
    throw StateError("pas d'asset APK pour la MAJ");
  }
  // 2.5 (prod3) : https uniquement — un http:// laisserait l'APK signer sur
  // le fil.
  if (!apkUrl.startsWith("https://")) {
    throw StateError("URL de téléchargement non https : $apkUrl");
  }
  final cache = await getTemporaryDirectory();
  final apk = File(p.join(cache.path, "tapitask-update.apk"));
  // 2.5 : STREAM vers le fichier (plus de readBytes plein-charge en RAM) +
  // timeout sur la phase de connexion.
  final client = http.Client();
  try {
    final streamed = await client
        .send(http.Request("GET", Uri.parse(apkUrl)))
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw StateError("téléchargement échoué : HTTP ${streamed.statusCode}");
    }
    await streamed.stream.pipe(apk.openWrite());
  } finally {
    client.close();
  }
  await _updaterChannel.invokeMethod("installApk", {"path": apk.path});
}

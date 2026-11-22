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
  final cache = await getTemporaryDirectory();
  final apk = File(p.join(cache.path, "tapitask-update.apk"));
  final bytes = await http.readBytes(Uri.parse(apkUrl));
  await apk.writeAsBytes(bytes);
  await _updaterChannel.invokeMethod("installApk", {"path": apk.path});
}

/// D-7 (spec 2026-11-25) : import/export de fichiers dans l'app.
///
/// Import : dialog de fichier natif (file_selector) — web inclus.
/// Export : [runExport] sauvegarde le corps renvoyé par le serveur
/// (dialog natif sur android/windows, téléchargement navigateur sur web).
library;

import "package:file_selector/file_selector.dart";

import "../data/api_client.dart";
import "file_save_web.dart" if (dart.library.io) "file_save_native.dart";

/// Seams test (D-7) : remplaçables — l'I/O dart:io et les dialogs ne
/// complètent pas dans la zone factice des widget tests (mêmes motifs
/// que `ApiClient.secureStorage`).
Future<XFile?> Function() pickFileForTesting = openFile;
Future<bool> Function(String content, String fileName) saveForTesting =
    saveFile;

/// Restaure les seams (teardown des widget tests).
void resetFileSeamsForTesting() {
  pickFileForTesting = openFile;
  saveForTesting = saveFile;
}

/// Import : ouvre le dialog, lit le fichier, POST /import (corps brut JSON
/// ou markdown — le serveur détecte le format).
/// Renvoie le nombre de listes créées ; null si l'utilisateur annule.
/// Lève si la lecture du fichier ou l'API échoue.
Future<int?> runImport(ApiClient api) async {
  final file = await pickFileForTesting();
  if (file == null) return null;
  final body = await file.readAsString();
  final r = await api.importFile(body, name: file.name);
  final lists = r["lists"];
  return lists is List ? lists.length : 0;
}

/// Export : fetch du corps brut [path] puis sauvegarde sous [fileName].
/// Renvoie false si l'utilisateur annule le dialog de sauvegarde
/// (web : le téléchargement est toujours déclenché → true).
/// Lève si l'API ou l'écriture échoue.
Future<bool> runExport(ApiClient api, String path, String fileName) async {
  final body = await api.getRaw(path);
  return await saveForTesting(body, fileName);
}

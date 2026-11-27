// Android/Windows : dialog de sauvegarde natif (file_selector,
// channel « getSavePath ») puis écriture du fichier.
import "dart:io";

import "package:file_selector/file_selector.dart";

Future<bool> saveFile(String content, String fileName) async {
  final loc = await getSaveLocation(suggestedName: fileName);
  if (loc == null) return false; // annulé par l'utilisateur
  await File(loc.path).writeAsString(content);
  return true;
}

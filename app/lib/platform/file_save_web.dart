// Web : pas de dialog de sauvegarde — téléchargement navigateur via
// package:web (même pattern qu'update_opener_web.dart, M6/D-4 prod4).
import "dart:js_interop";

import "package:web/web.dart" as web;

Future<bool> saveFile(String content, String fileName) async {
  final blob = web.Blob(<web.BlobPart>[content.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement("a") as web.HTMLAnchorElement;
  a.href = url;
  a.download = fileName;
  web.document.body!.appendChild(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
  return true;
}

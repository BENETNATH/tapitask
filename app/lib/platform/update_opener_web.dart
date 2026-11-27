// M6 (D-4, prod4) : dart:html → package:web (l'ancien import est
// deprecated ; même API, pas de flag wasm).
import "package:web/web.dart" as web;

void openReleasePage(String url) => web.window.open(url, "_blank");

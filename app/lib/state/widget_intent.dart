/// Valide une URI de lancement venue d'un widget
/// (spec 2026-11-16-android-deep-link-hardening).
///
/// Renvoie :
///  - l'id de liste (si `?list=<uuid>` est valide et accessible),
///  - `""` pour « ouvrir le quick-add par défaut » (pas de param list),
///  - null si la URI doit être ignorée (inconnue, invalide, non accessible).
String? validateQuickAddUri(Uri? uri, Set<String> accessibleListIds) {
  if (uri == null) return null;
  if (uri.scheme != "tapitask") return null;
  // "tapitask://quickadd" est parsé comme authority (host), pas path —
  // on accepte les deux formes, tout autre location est rejeté.
  if (uri.path != "quickadd" && uri.host != "quickadd") return null;
  final list = uri.queryParameters["list"];
  if (list == null) return "";
  if (list.isEmpty) return null;
  final uuid = RegExp(
      r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
      caseSensitive: false);
  if (!uuid.hasMatch(list)) return null;
  // Casse stricte : les ids de la DB sont en minuscules.
  if (!accessibleListIds.contains(list)) return null;
  return list;
}

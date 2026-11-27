# Spec 2026-11-27 — Nettoyage dette qualité app (mécanique, bas risque)

**Statut** : à implémenter. **Périmètre** : `app/lib/` uniquement
(pas de refactor visuel/structurel — voir spec séparée
`2026-11-27-app-refactor.md` pour `list_screen.dart`/
`today_screen.dart`/`todo_all_screen.dart`). Référence :
`specs/2026-11-27-audit-findings.md`.

## 1. Extraire `_withRetry` dans `ApiClient` (6 duplications)

`lib/data/api_client.dart` — le bloc « requête → si 401 et
`!retried` et `await _tryRefresh()` réussit → relance avec
`retried: true` » est recopié identique dans `patch` (L148-164),
`delete` (L181-188), `get` (L190-198), `getRaw` (L202-210),
`getList` (L233-239+), et une variante avec `auth` conditionnel dans
`_post` (L243-257). `importFile` (L215-231) a une variante SANS le
garde `!retried` (risque de boucle si le refresh "réussit" mais le
token reste invalide) — à harmoniser au passage.

Nouveau helper privé :
```dart
/// Exécute [call] ; si la réponse est 401 et qu'un refresh réussit,
/// relance UNE SEULE fois (3.7 prod3 : un 2e 401 après refresh se
/// propage, pas de boucle infinie). [retryOn401] = false pour les
/// appels non authentifiés (ex. /auth/login via _post(auth: false)).
Future<http.Response> _withRetry(
  Future<http.Response> Function() call, {
  bool retryOn401 = true,
}) async {
  final r = await call();
  if (retryOn401 && r.statusCode == 401 && await _tryRefresh()) {
    return call();
  }
  return r;
}
```
Chaque méthode publique devient 2-3 lignes, ex. :
```dart
Future<Map<String, dynamic>> patch(
    String path, Map<String, dynamic> body) async {
  final r = await _withRetry(() => _http.patch(
      Uri.parse("$baseUrl$path"),
      headers: {
        "Authorization": "Bearer $accessToken",
        "Content-Type": "application/json"
      },
      body: jsonEncode(body)).timeout(timeout));
  _check(r);
  return jsonDecode(r.body) as Map<String, dynamic>;
}
```
Même traitement pour `delete`, `get`, `getRaw`, `getList`,
`importFile` (ajoute le garde manquant au passage), et `_post`
(`retryOn401: auth`). **Le paramètre `retried` disparaît des
signatures publiques** — vérifié par grep (`retried:\s*true`, 6
occurrences, toutes des self-recursions internes, aucun appelant
externe ne passe `retried:`) : supprimable sans casser d'appelant.

Test : les tests existants de `ApiClient` (401 → refresh → retry, 2e
401 → propage) doivent rester verts SANS modification — c'est la
preuve de non-régression. Si `importFile` n'a aucun test de ce
scénario, en ajouter un (il n'en avait pas, le garde `!retried`
manquant signale justement l'absence de couverture de ce cas).

## 2. `database.dart` — `getList` doit utiliser `.getSingleOrNull()`

`lib/data/database.dart:215-222` — `getList(id)` fait
`try { return await (...).getSingle(); } catch (_) { return null; }`,
qui avale TOUTE erreur (vraie panne DB comprise), pas seulement
« introuvable ». `getItem` (L329-331) utilise correctement
`.getSingleOrNull()`. Remplacer :
```dart
Future<LocalList?> getList(String id) =>
    (select(localLists)..where((l) => l.id.equals(id))).getSingleOrNull();
```
(adapter au nom exact de la table/méthode — lire le contexte exact de
`getList` avant d'écrire le remplacement, le signature peut différer
légèrement selon le nom de la requête drift sous-jacente). Test :
appeler `getList` sur un id inexistant → retourne `null` (déjà couvert
probablement) ; si un test simulait une erreur DB réelle avalée, il
doit maintenant voir l'erreur remonter (sinon, test à ajouter : mock
qui fait lever une exception non liée à "not found" → doit se
propager, pas `null`).

## 3. `applyWidgetToggles()` — perte silencieuse d'un toggle en échec

`lib/state/app_state.dart:332-341` — si `db.setDone(id, …)` échoue pour
un id (catch existant), cet id est quand même passé à
`WidgetService.clearToggles(ids)` juste après, qui l'efface
définitivement (pas de retry, pas de log). Ne passer à `clearToggles`
que les ids réellement appliqués avec succès :
```dart
Future<void> applyWidgetToggles() async {
  final toggles = await WidgetService.pendingToggles(); // ou équivalent existant
  final applied = <String>[];
  for (final entry in toggles) {
    try {
      await db.setDone(entry.id, entry.done);
      applied.add(entry.id);
    } catch (e) {
      debugPrint('applyWidgetToggles: setDone failed for ${entry.id}: $e');
    }
  }
  if (applied.isNotEmpty) {
    await WidgetService.clearToggles(applied);
    notifyListeners();
  }
}
```
(adapter aux noms exacts des variables/méthodes en lisant le code
actuel avant d'écrire — la boucle/signature peut différer légèrement ;
le PRINCIPE à respecter est : ne clear que les ids traités avec
succès, logguer l'échec, garder le `notifyListeners()` existant après
les `setDone` — déjà identifié comme nécessaire par un fix précédent
P3, NE PAS le perdre).

Test : un id dont `db.setDone` lève une exception → n'est PAS dans
l'appel à `clearToggles` (vérifiable via un mock/fake de
`WidgetService` ou de `db` qui enregistre les ids reçus) ; les autres
ids de la même liste, eux, sont bien effacés.

## 4. `catch (_) {}` muets sans log (incohérence de pattern)

Sites concernés (vérifier chacun avant d'ajouter le log — ne pas
ajouter de log sur un catch qui gère délibérément un cas NORMAL, ex.
parsing optionnel où l'absence est attendue) :
`alert_service.dart:29`, `tray_controller.dart:133/162/165`,
`flyout_bridge.dart:89`, `update_service.dart:99`, `api_client.dart:116/315`,
`sync_service.dart:98`, `main.dart:121`, `app_state.dart:141/147/446/460/512/526/871/881`,
`home_screen.dart:549` (les occurrences `app_state.dart:332/339` sont
couvertes par le point 3 ci-dessus, ne pas les re-traiter ici).

Pour chaque site : remplacer `catch (_) {}` par
`catch (e) { debugPrint('<contexte>: $e'); }` où `<contexte>` est une
chaîne courte identifiant la fonction/l'opération (pas générique). Si
la lecture du contexte montre qu'un catch est un filtre DÉLIBÉRÉ
« échec attendu, rien à signaler » (ex. parsing best-effort d'une
valeur optionnelle où `null`/valeur par défaut est le comportement
voulu, pas une erreur), NE PAS ajouter de log — documenter dans le
rapport final lesquels ont été laissés tels quels et pourquoi.

Pas de nouveau test requis (ajout de log pur, pas de changement de
comportement) — `flutter analyze` + la suite existante restent la
preuve.

## Vérification finale

1. `dart run build_runner build --delete-conflicting-outputs` (OBLIGATOIRE
   avant toute analyse — fichier généré gitignored).
2. `flutter analyze --no-fatal-infos` → `No issues found!`.
3. `flutter test` (suite complète) → tous verts, 0 régression sur les
   150 tests existants.
4. `git status --short` : uniquement des fichiers sous `app/lib/` (+
   tests associés si ajoutés) + cette spec. Rien sous
   `app/windows/runner/` (hors périmètre, déjà traité).
5. Ne rien committer.

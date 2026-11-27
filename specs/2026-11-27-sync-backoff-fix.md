# Spec 2026-11-27 — Fix backoff WebSocket inopérant (SyncService)

**Statut** : à implémenter (bug réel trouvé en marge de
`specs/2026-11-27-app-tests.md` point 3b). **Périmètre** :
`app/lib/data/sync_service.dart` + son test UNIQUEMENT.

## Cause identifiée (vérifiée empiriquement, probe supprimé après usage)

`listenRealtime()` (`sync_service.dart:323-344`) pose
`_wsFailures = 0;` (ligne 344) JUSTE APRÈS avoir lancé
`WebSocketChannel.connect(...)` et envoyé le message d'auth — PAS
après confirmation que la connexion a réellement réussi. Résultat
mesuré : le compteur repart de 0 à CHAQUE tentative de reconnexion
(réussie ou non), donc `_scheduleReconnect()` (ligne 365-375) calcule
toujours `2 << (0+1) = 4s` — jamais la progression exponentielle ni le
plafond 5 min documentés en commentaire (lignes 24, 372).

## Fix

Déplacer le reset de `_wsFailures` sur la confirmation RÉELLE de
connexion (`_ws!.ready` qui complète avec succès), pas
inconditionnellement :

```dart
try {
  final wsUrl = api.baseUrl.replaceFirst("http", "ws");
  _ws = WebSocketChannel.connect(Uri.parse("$wsUrl/ws"));
  // Échec de connexion : [ready] complète en erreur — sans listener,
  // c'est une erreur non gérée (le stream s'occupe déjà du cas
  // connecté-puis-coupé via onError). Succès : SEUL point où le
  // compteur d'échecs doit repartir à zéro (sinon le backoff
  // exponentiel ne progresse jamais, cf. audit 2026-11-27).
  _ws!.ready.then((_) => _wsFailures = 0).catchError((_) {
    _scheduleReconnect();
  });
  _ws!.sink.add(jsonEncode({"token": api.accessToken}));
  _wsSub = _ws!.stream.listen(
    ...
```
(retirer la ligne `_wsFailures = 0;` qui suivait directement
`sink.add(...)` — le reste de la fonction ne change pas.)

## Test (TDD, rouge d'abord)

Réutiliser le pattern d'échec WS déjà établi dans
`test/audit_prod3_test.dart` (serveur HTTP local loopback qui refuse
l'upgrade WebSocket, ou ferme la connexion après ouverture — les deux
modes ont été vérifiés par le probe de l'audit). Avec ce serveur en
échec permanent :
1. Déclencher 2-3 tentatives de reconnexion successives (via le
   mécanisme existant de retry — pas d'accès à l'implémentation privée
   au-delà de ce que les tests actuels font déjà pour « pas de
   doublon »).
2. Mesurer (horodatage réel, ou horloge contrôlée si le fichier de
   test en a déjà l'habitude) le délai entre chaque tentative
   successive.
3. **Rouge sur le code actuel** : délai constant (~4s à chaque fois).
   **Vert après fix** : délai croissant (ex. tentative 2 ≈ 4s,
   tentative 3 ≈ 8s — tolérance large acceptable, l'important est la
   PROGRESSION, pas la valeur exacte à la milliseconde près, un test
   de timing exact serait flaky).

## Vérification

1. `dart run build_runner build --delete-conflicting-outputs` d'abord.
2. `flutter analyze --no-fatal-infos` → `No issues found!`.
3. `flutter test` (suite complète) → verte, 0 régression sur les 172
   tests existants + le nouveau test de backoff.
4. `git status --short` : uniquement `sync_service.dart` + son fichier
   de test.
5. Ne rien committer.

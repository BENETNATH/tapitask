# Micro-lot A2-Android + C1.7 test (2026-11-24)

Suite du lot C1+C2 (commit 3974dc2). Deux items ciblés, TDD, surface minimale.

## A2 — Dialog d'update au boot : ajouter Android
L'arbitrage A2 (dialog de mise à jour au boot si une update est dispo) a été
implémenté **Windows seul** dans `3974dc2` (le switch garde un cas android
mort). Consigne user (2026-11-24) : l'étendre aussi à **Android, si possible**.
- Le flux update Android (téléchargement APK + installation) existe déjà dans
  `UpdateDialog` / le flux §B des settings (`installApk`) — réutiliser ce
  composant au boot, pas en dupliquer.
- Le dialog au boot doit rester non bloquant (post-`runApp`, comme côté
  Windows) et respecter le comportement existant (boutons, états de
  téléchargement déjà corrigés dans le lot).
- Si la présentation du dialog au boot sur Android se heurte à une contrainte
  réelle (ex. cycle de vie, permission, comportement système) : documenter la
  contrainte en commentaire et livrer le maximum réalisable (le check au boot
  + la presentation dès que c'est faisable).

## C1.7 — Test manquant : verify-email sans baseUrl
Le fix code est en place (`_verifyEmail` appelle `_applyServerUrl()` avant le
POST + catch générique), mais le 3e test attendu par la spec
`2026-11-24-audit-c1c2-corrections.md` (§C1.7) n'a pas été écrit :
**scénario « installation fraîche, baseUrl non appliqué, cliquer sur Vérifier
mon email → pas de crash »** (avant le fix, `Uri.parse("/auth/verify-email")`
levait un `ArgumentError` non géré).
- Écrire ce test dans le fichier de tests existant du lot
  (`app/test/audit_c1c2_test.dart` ou le fichier concerné par les tests C1.7).
- Le test doit échouer sur le code pré-fix (argumenter pourquoi dans un
  commentaire) et passer sur le code actuel.

## Livrables
- Flutter : `flutter analyze --no-pub` propre + `flutter test` vert (baseline
  105 + nouveaux).
- Commit conventionnel (fix), review record (REVIEWER=hermes
  scripts/review.py record), push, CI verte.
- La spec est commitée avec le lot ; le rapport d'audit
  `specs/2026-11-24-audit-security.md` reste **untracked** (consigne user).

# Lot O — widget sans couleur, clavier quickadd, quickadd hors session, login visible

## Contexte

Quatre défauts confirmés sur device après la refonte Flutter 3.50 :

1. **Blanc sur blanc (widget)** — liste sans couleur en mode sombre : le fond
   reste le default du layout (`#F7FAFA`, `res/drawable/widget_background.xml`)
   alors que les textes sont theme-aware (titre `rgb(235,235,235)`, items
   `rgb(226,226,226)` dans `ListWidgetProvider.render()`). Cause :
   `setBackgroundColor` n'est appelé QUE si `list_<i>_color` est non-null —
   il n'y a pas de fond par thème quand la liste est sans couleur.
2. **Clavier non ouvert (quickadd)** — le deep-link focalise bien le champ
   d'ajout (curseur visible : `requestFocus()` post-frame fonctionne) mais
   l'IME ne s'ouvre pas ; un tap sur le champ l'ouvre instantanément. Le
   `show` IME est avalé juste après le cold-start : la fenêtre demande
   `SOFT_INPUT_STATE_VISIBLE` à l'`onResume` (lot L) sans cible de saisie,
   puis la requête programmatique arrive avant que la fenêtre ne soit
   installée.
3. **Quickadd bloqué hors session** — `_applyWidgetUri` rejette avec
   `no-token` quand `api.accessToken == null` (app_state.dart, bloc
   « session requise » de la doc). Surprotecteur : l'app est local-first —
   l'écriture drift est inconditionnelle et le sync n'est déclenché que si
   token (`app_state.dart`, `addItem` : `if (!source.localOnly &&
   api.isConfigured && api.accessToken != null) sync.syncSoon();`). La
   navigation et l'ajout local marchent donc hors session ; l'item sera
   synchronisé au prochain login.
4. **Login peu visible (settings)** — l'item « Compte & serveur » (→
   `/login`) est le tout dernier du menu, s'affiche « Non configuré » en
   texte discret, et le menu s'arrête très court en dessous. Demande user :
   plus de longueur sous le dernier item + item login bien visible quand
   non connecté.

## Changements

### O1 — Kotlin `app/android/app/src/main/kotlin/com/tapitask/tapitask/ListWidgetProvider.kt`

Dans `render()`, ajouter la branche `else` (aucune couleur) à l'if
`colorHex != null` :

- `colorHex == null && dark` → `setBackgroundColor(Color.rgb(27, 27, 27))` (`#1B1B1B`)
- `colorHex == null && !dark` → `setBackgroundColor(Color.rgb(247, 250, 250))` (`#F7FAFA`, explicite = default du drawable)

Listes colorées : inchangées. Comme déjà le cas avec les couleurs, le fond
devient plat (pas de coins arrondis ni de stroke) — cohérent.

### O2 — Dart `app/lib/ui/list_screen.dart` (deep-link `focusAdd`)

Remplacer le post-frame `requestFocus` d'`initState` par une requête différée
d'environ 400 ms, avec commentaire de cause (show IME avalé après cold-start) :

```dart
Future<void>.delayed(const Duration(milliseconds: 400), () {
  if (mounted) _addFocus.requestFocus();
});
```

Garder la sonde `TAPITASK-FLOW ListScreen: requestFocus` dans le bloc différé
(elle doit loguer le moment réel de la requête, plus au montage).

### O3 — Dart `app/lib/state/app_state.dart`

Retirer le gate `no-token` de `_applyWidgetUri` (bloc
`if (api.accessToken == null) { … no-token … return; }`). Les validations
scheme / path / UUID / membership locale restent intactes (membership via
`db.visibleLists()` — locale, fonctionne hors session). Mettre à jour le
commentaire de doc (« session requise » → local-first : navigation +
écriture locale, sync au prochain login si item marqué dirty).

**TDD — test d'abord** dans `test/app_state_widget_launch_test.dart`
(à faire rougir avant le patch) : « quickadd sans session : flags posés
(notify différé post-frame), id liste posé » — même forme que le test
existant mais `state.api.accessToken = null` (ne PAS poser de token), URI
valide sur une liste locale → `quickAddRequested == true`,
`quickAddListId == kListId` après post-frame. Les deux tests existants
(token posé) doivent rester verts sans modification.

### O4 — Dart `app/lib/ui/settings_screen.dart`

Section « Compte » :

- **Non connecté** (`s.api.accessToken == null`) : remplacer le `_tapRow`
  discret par un `ElevatedButton.icon` plein (couleur primaire),
  libellé `S.login` (« Se connecter » / « Sign in » — chaîne existe),
  icône `Icons.login`, `onPressed: () => Navigator.pushNamed(context, "/login")`.
  Hauteur ~44, même padding horizontal 16 que les autres items.
- **Connecté** : conserver le `_tapRow` actuel (« Compte & serveur » +
  URL serveur).
- Fin du menu : `SizedBox(height: 24)` → `SizedBox(height: 48)` (respiration
  sous le dernier item).

## Tests / vérification

- `flutter test` — suite complète verte (test O3 ajouté ; O2/O4 sans test
  unitaire : comportement device).
- `flutter build apk --debug` vert.
- Pas de test Kotlin (pas d'infra) : O1 par source + retest device.
- Device (un passage utilisateur) :
  a. liste sans couleur, mode sombre → fond sombre, textes lisibles ;
  b. liste colorée inchangée (les deux modes si possible) ;
  c. widget « + » CONNECTÉ (cold et warm) → liste ouverte ET clavier ouvert
     sans tap ;
  d. widget « + » NON connecté (kill l'app, logout si besoin) → liste
     ouverte, curseur sur le champ, clavier ouvert ;
  e. settings non connecté → item « Se connecter » plein et visible en fin
     de menu, respiration correcte sous le dernier item ; settings connecté
     → row inchangée.
- `adb logcat -s TAPITASK-FLOW:*` du test « + » connecté : la sonde
  `requestFocus` doit apparaître ~400 ms après `maybeQuickAdd: push`, et le
  test non connecté doit montrer `applyWidgetUri … → quickAddRequested`
  (plus de `no-token`).

## Hors périmètre

- Retrait des sondes TAPITASK-FLOW : lot dédié APRÈS validation complète
  (écran rouge ✓, clavier, couleur, quickadd hors session, settings).
- « + » non connecté qui ouvre l'écran de login au lieu de la liste :
  comportement NON souhaité — le user veut la liste (local-first).

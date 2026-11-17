# Spec — lot E : RenderFlex overflow du titre de toolbar ListScreen

Date : 2026-11-17 · Repo : tapitask · Réf source : HEAD `05b8db4` · Suite de référence : `cd app && flutter test` (baseline 22 passed).

TDD : test d'abord (rouge), fix minimal (vert). Surface minimale (style ponytail) : pas de refactor, pas de feature, pas de commentaire superflu, pas de nouvelle dépendance. **Ne pas committer** (l'assistant commit après vérification).

## Diagnostic (vérifié)

Bug visuel rapporté au device (APK debug, 2026-11-17) : un bandeau rayé jaune/noir
avec texte vertical rouge "OVERFLOWED BY N px" chevauche le titre de la toolbar
de l'écran liste — c'est l'indicateur de débordement de `RenderFlex` de Flutter
en mode debug (en release, le contenu est rogné sans indication).

`app/lib/ui/list_screen.dart`, AppBar (L151-217) :
- branche ≥ 2 listes (L159-215) : le titre est une `Row(mainAxisSize.min)`
  `[IconButton ◀, PopupMenuButton (child: Text "titre ▾"), IconButton ▶]`.
  Aucun enfant n'est réductible : `Text` sans ellipsis, pas de `Flexible`.
  Sur écran étroit (360dp) avec un titre long, la Row dépasse la largeur
  disponible (flèche retour + titre + 3 icônes actions) → overflow.
- branche 1 liste (L159-166) : `Text` seul, sans ellipsis → même overflow
  pour un titre long (le `Flexible` du Toolbar de l'AppBar n'aide pas :
  le `Text` reçoit des contraintes lâches et déborde).

Reproduction déterministe en test : `MaterialApp(home: ListScreen(...))` pumpé
en 360x640 logique avec des titres longs.

## Fichiers autorisés (4)

1. `app/lib/state/app_state.dart`
2. `app/lib/ui/list_screen.dart`
3. `app/test/list_screen_overflow_test.dart` (nouveau)
4. rien d'autre.

## Fix

### 1. `app_state.dart` — injection du db pour les tests

Remplacer le champ initialisé directement par un constructeur injectable
(même comportement par défaut, aucune autre ligne touchée) :
```dart
class AppState extends ChangeNotifier {
  final AppDb db;
  AppState({AppDb? db}) : db = db ?? AppDb();
```
(remplace `final AppDb db = AppDb();` en L23 — le reste de la classe inchangé)

### 2. `list_screen.dart` — branche 1 liste (L160-166) : ellipsis sur le titre

```dart
              return Text(list?.title ?? "Liste",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle( ... style inchangé ...));
```

### 3. `list_screen.dart` — branche ≥ 2 listes (L168-215) : `Flexible` + ellipsis

Enrouler le `PopupMenuButton` (L178-206) dans `Flexible`, et ajouter
`maxLines: 1, overflow: TextOverflow.ellipsis` à son `Text` child (L197-205).
Les deux `IconButton` (◀ / ▶) restent fixes, la Row garde
`mainAxisSize: MainAxisSize.min`.

### 4. `app/test/list_screen_overflow_test.dart` — tests de régression

2 `testWidgets` :
- **≥ 2 listes, titre long** : db mémoire (`AppDb.forTesting(NativeDatabase.memory())`),
  `AppState(db: db)`, 2 listes (celle affichée avec un titre long,
  ex. "Entretien extérieur, abords, gouttières et volets de la maison"),
  vue étroite `tester.view.physicalSize = Size(720, 1280)` +
  `devicePixelRatio = 2.0` (= 360x640 logique), pump
  `MaterialApp(home: ListScreen(state: state, listId: id1))`,
  `pumpAndSettle()`, `expect(tester.takeException(), isNull)`
  (ROUGE avant fix : RenderFlex overflow ; VERT après),
  puis `expect(find.byType(PopupMenuButton<String>), findsOneWidget)`,
  `db.close()` en tearDown.
- **1 liste, titre long** : idem avec une seule liste,
  `expect(tester.takeException(), isNull)`
  (ROUGE avant fix, VERT après), et le titre est visible
  (`find.byType(Text)` dans l'AppBar findsOneWidget).

## Acceptation

- `cd app && flutter test` : baseline 22 + 2 nouveaux = 24 passed, 0 failed.
- Les 2 nouveaux tests sont ROUGES avant le fix (vérifier l'ordre TDD).
- `git diff` limité aux 3 fichiers existants + le nouveau test.
- Aucun autre fichier modifié.

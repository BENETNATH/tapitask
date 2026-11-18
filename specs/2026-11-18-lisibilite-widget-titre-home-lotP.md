# Lot P — lisibilité widget, titre écran liste, home à jour

Date : 2026-11-18
Statut : à implémenter
Suite de : lot O (`ef2baee`). Les 3 défauts ci-dessous sont sortis des
captures d'utilisation de l'APK lot O (13:16:44, 13:17:18, 13:18:42, 13:19:14)
et sont chacun vérifiés dans le code avant d'être spécifiés.

## P1 — Widget : texte titre + items illisible (liste sans couleur)

**Symptôme** (capture 13:17:18, analyse pixels) : le widget liste montre un
fond blanc `rgb(246,250,251)` ; les lignes titre (`test (1/2)`) et item
(`☐ truc`) ne rendent AUCUN texte visible ; les boutons teal (＋ / ouvrir,
drawables XML) sont visibles et corrects.

**Cause (vérifiée dans le code)** :

- Le Dart écrit `list_<i>_color = list.color ?? ""`
  (`app/lib/platform/widget_service.dart:43`) : une liste sans couleur écrit
  la chaîne VIDE, jamais null.
- Le provider lit `val colorHex = data.getString("list_${index}_color", null)`
  puis teste `if (colorHex != null)`
  (`app/android/app/src/main/kotlin/com/tapitask/tapitask/ListWidgetProvider.kt:183-197`) :
  `""` passe la condition → `Color.parseColor("")` lève
  `IllegalArgumentException` → avalée par le `catch (_: Exception)` (ligne 203)
  → **aucun appel `setInt("setBackgroundColor", …)` n'est posé** → le fond
  reste le default du drawable XML `#F7FAFA` (blanc,
  `res/drawable/widget_background.xml`).
- Le thème est résolu côté Dart (`widget_service.dart:28-34`,
  `PlatformDispatcher.platformBrightness`) ; téléphone en mode sombre →
  `theme = "dark"` → couleurs texte claires posées en
  `ListWidgetProvider.kt:205-212` (titre `rgb(235,235,235)`, items
  `rgb(226,226,226)`) → **texte clair sur fond blanc = illisible**.
- Conséquences : (a) le fond par thème du lot O (else, `rgb(27,27,27)` en
  dark) n'est JAMAIS atteint pour une liste sans couleur ; (b) tout hex
  illisible produit le même blanc.

**Fix (cible de référence)** : extraire le calcul du fond en fonction pure
dans le companion object, traiter `""` comme absence de couleur, et tomber sur
le fond par thème en cas d'échec de parse — le fond est TOUJOURS posé.

```kotlin
// companion object (ListWidgetProvider.kt)
/// Fond du widget : couleur de liste éclaircie (light) / assombrie (dark),
/// sinon fond par thème. `""` (le Dart écrit `list.color ?? ""`) = liste
/// sans couleur ; un hex illisible retombe sur le fond par thème — le fond
/// est toujours posé, jamais le default du drawable.
fun widgetBackground(dark: Boolean, colorHex: String?): Int {
    val themeBg = if (dark) Color.rgb(27, 27, 27) else Color.rgb(247, 250, 250)
    if (colorHex == null || colorHex.isEmpty()) return themeBg
    return try {
        val c = Color.parseColor(colorHex)
        if (dark) {
            Color.rgb(Color.red(c) / 2, Color.green(c) / 2, Color.blue(c) / 2)
        } else {
            Color.rgb((Color.red(c) + 255 * 3) / 4,
                      (Color.green(c) + 255 * 3) / 4,
                      (Color.blue(c) + 255 * 3) / 4)
        }
    } catch (_: Exception) {
        themeBg
    }
}
```

Dans `render()`, remplacer le bloc entier des lignes 184-204 (try/catch avec
les deux branches setBackgroundColor) par :

```kotlin
        views.setInt(R.id.widget_root, "setBackgroundColor",
            widgetBackground(dark, colorHex))
```

`val colorHex = data.getString("list_${index}_color", null)` (ligne 183) est
conservé. Les couleurs texte (205-212) et le reste du rendu sont inchangés.

**Tests** : aucun test Kotlin (décision projet enregistrée : pas d'infra
unitaire Kotlin ; un fix Kotlin se prouve par la source + retest device).
`flutter test` doit rester verte ; `flutter build apk --debug` vérifie la
compilation du Kotlin.

**Valeurs attendues** (pour le retest device) :
- dark, sans couleur : fond `rgb(27,27,27)`, titre `rgb(235,235,235)`,
  items `rgb(226,226,226)`
- light, sans couleur : fond `rgb(247,250,250)`, titre `#00695C`, items `#1B1B1B`
- dark, `#00897B` : fond `rgb(0,68,61)`
- light, `#00897B` : fond `rgb(191,225,222)`

## P2 — Écran liste : le nom de la liste est tronqué à rien (≥ 2 listes)

**Symptôme** (captures 13:16:44 et 13:19:14) : avec 2 listes actives, l'AppBar
de ListScreen ne montre aucun nom de liste entre les chevrons ◀ / ▶ (« machine
e » → zone vide ; « test » → « t... »). Le titre est rendu dans le
`PopupMenuButton` central de la Row. La branche 1-liste (Text simple) est non
affectée.

**Cause (vérifiée dans le code)** : `app/lib/ui/list_screen.dart:190-192` —
`Row(mainAxisSize: MainAxisSize.min)` dont l'enfant central est `Flexible`
(ligne 200). Dans une Row dimensionnée au minimum, l'espace distribué au flex
est nul (la Row se taille aux deux IconButtons) : le `Text("<titre> ▾")`
reçoit une largeur max ~0 → ellipsis à zéro caractère (un caractère selon la
largeur résiduelle — d'où « t... » sur une capture et rien sur l'autre).

**Fix (cible de référence)** : dans la Row du titre (`list_screen.dart:190`) :
- `mainAxisSize: MainAxisSize.min` → `mainAxisSize: MainAxisSize.max`
- `Flexible(` (ligne 200) → `Expanded(`

Le titre prend alors toute la place restante entre les chevrons et s'ellipse
proprement (`maxLines: 1` + `TextOverflow.ellipsis` déjà en place sur le
Text). Aucun autre changement dans cet écran.

**Tests (TDD, `flutter test`)** : ajouter dans
`app/test/list_screen_overflow_test.dart` (ou fichier dédié
`list_screen_title_test.dart`) :
- 2 listes, `pumpWidget(MaterialApp(home: ListScreen(state, listId: id1)))`,
  view `720x1280 @ dpr 2.0` comme les tests existants, `pumpAndSettle`
- `expect(tester.takeException(), isNull)`
- localiser le `Text` du titre (`find.text("<titre de la liste 1> ▾")`) et
  exiger `tester.getSize(title).width >= 40`
  (avant le fix : largeur ~0 → rouge ; après : ~64 px dans la view de test →
  vert)

## P2b — Suite P2 : le titre n'a AUCUNE place (back button + 3 actions)

**Constat (vérifié par mesure widget test, géométrie device : view
`640x1280 @ dpr 2.0` = 320 logique, ListScreen POUSSÉ via Navigator donc avec
back button, 2 listes, titre « machine e », code P2 déjà appliqué)** :

- zone titre de l'AppBar = **88 px** (320 − 56 back − 144 (3 icônes d'action)
  − 32 padding toolbar)
- la Row du titre contient déjà 2 chevrons de 48 px = 96 px > 88 px
- résultat : **titre de largeur 0.0 px + RenderFlex overflow 8 px**
  (bandeau debug sur device, titre invisible en release)

Le fix P2 (Row max + Expanded) est donc nécessaire mais **insuffisant** :
avec 3 icônes d'action, le titre n'a structurellement aucune place, quelle
que soit la Row. Les captures device (« t... » / rien) correspondent à ce
calcul (titre ≈ 0-20 px).

**Fix (cible de référence)** : regrouper les 2 actions « Vider les cochés »
(`clean`, icône `delete_sweep_outlined`, tooltip `S.cleanDoneTooltip`) et
« Partager » (`share`, icône `share`, tooltip `S.share`) dans le
`PopupMenuButton` ⋮ EXISTANT de l'AppBar (`list_screen.dart:278-330`) :

- retirer les deux `IconButton` correspondants de `actions:`
- ajouter en tête du `itemBuilder` du menu deux `PopupMenuItem` :
  `value: "clean"` (même icône/label que l'ancien IconButton) puis
  `value: "share"`
- dans le `switch`/`if` de `onSelected` du menu : ajouter
  `action == "clean"` → la confirmation + `state.purgeDone(widget.listId)`
  déjà présentes dans l'ancien IconButton (déplacer, pas dupliquer la
  logique) ; `action == "share"` → le `Navigator.push(ShareScreen …)` déjà
  présent

Après : actions = 1 icône → zone titre = 320 − 56 − 48 − 32 = 184 px →
titre = 184 − 96 (chevrons) = **88 px** → « machine e ▾ » (~80 px) tient
entier, les titres plus longs s'ellipsent proprement.

Le fix P2 (Row max + Expanded) est CONSERVÉ (le bon patron ; sans lui le
test P2 original échoue).

**Tests (TDD, `flutter test`)** : test device-faithful dans
`app/test/list_screen_overflow_test.dart` (ou dédié) :
- 2 listes (titre « machine e »), `pumpWidget(MaterialApp(home: Builder →
  Scaffold(body: ElevatedButton "go")))`, tap du bouton,
  `Navigator.push(MaterialPageRoute(builder: (_) => ListScreen(state, listId)))`
  (→ le back button apparaît), view `640x1280 @ dpr 2.0`, `pumpAndSettle`
- `expect(tester.takeException(), isNull)` (aucun overflow)
- `find.text("machine e ▾")` : `tester.getSize(...) >= 80` de large
  (avant P2b : overflow + 0 px → rouge ; après : 88 px → vert)

## P3 — Home : items cochés dans le widget non reflétés

**Symptôme** (capture home 13:18:42 ; listes local-only) : un item coché dans
le widget reste affiché non-coché dans l'aperçu du home après réouverture de
l'app.

**Cause (vérifiée dans le code)** : `app/lib/state/app_state.dart:211-227` —
`applyWidgetToggles()` écrit `db.setDone(id, true, …)` pour chaque id en
attente puis `clearToggles()` mais **n'appelle jamais `notifyListeners()`**
(contrairement à `toggleItem()`, lignes 579-585). Au resume — l'activity
singleTask est resumée sans re-init, `app/lib/main.dart:89-98` — le home
conserve son aperçu `FutureBuilder` résolu avant l'écriture ; pour une liste
local-only, `sync.fullSync()` ne pousse rien → aucun callback `onChanged` → le
home ne rebâtit jamais. Au cold start le défaut est masqué par les rebuilds
ultérieurs de `init()`.

**Fix (cible de référence)** : dans `applyWidgetToggles()`, juste après la
boucle `for (final id in ids)` (ligne 221) et avant
`await WidgetService.clearToggles();` (ligne 222), ajouter :

```dart
    notifyListeners();
```

Le `if (ids.isEmpty) return;` amont garantit qu'on ne notifie qu'après une
réelle application ; l'idempotence (double appel au resume + au cold start)
est inchangée.

**Tests (TDD, `flutter test`)** : étendre `app/test/widget_toggles_test.dart`
(même infrastructure : mock du canal `home_widget`, `AppDb.forTesting`) :
- « les listeners sont notifiés quand un toggle en attente est appliqué » :
  compteur sur `state.addListener`, `store["widget_toggled"] = itemId`,
  `await state.applyWidgetToggles()` → `expect(count, greaterThan(0))`
- « rien en attente : aucun notify » : `count` reste `0` (retour précoce)

## Hors périmètre

- Les sondes `TAPITASK-FLOW` restent en place (lot dédié de nettoyage après
  validation complète des lots O+P).
- L'aperçu du home n'affiche QUE les items non-cochés
  (`uncheckedItemsOf`, max 3) : by design, pas un bug.
- `label_add` = « ＋ » seul dans le widget : conforme (boutons jugés OK).
- `specs/2026-11-18-widget-color-ime-lotO.md` est implémentée et commitée
  (`ef2baee`) : HORS périmètre de ce lot.
- Aucune nouvelle dépendance, aucun changement de pubspec.

## Vérification

1. `cd app && flutter test` — suite complète verte (36 tests existants +
   nouveaux)
2. `flutter build apk --debug` — vert (JAVA_HOME=17 exporté)
3. Diff minimal : les 3 fichiers cibles + les fichiers de tests uniquement
4. Retest device (checklist user) :
   a. Widget, liste SANS couleur, téléphone en mode sombre → fond sombre,
      titre + items lisibles
   b. Idem, thème « Clair » dans les paramètres → fond blanc, texte sombre
   c. Widget, liste AVEC couleur → fond teinté, texte lisible
   d. Écran liste avec ≥ 2 listes → nom de la liste lisible dans le titre
   e. Cocher un item dans le widget, rouvrir l'app → l'item disparaît de
      l'aperçu du home (liste local-only)

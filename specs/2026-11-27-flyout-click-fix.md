# Spec 2026-11-27b — Fix volet Windows : clic inactif sur les cases à cocher

**Statut** : à implémenter (bugfix 0.6.1).
**Périmètre** : `app/windows/runner/flyout_window.cpp` UNIQUEMENT. Zéro
changement Dart (`flyout_bridge.dart` inchangé — le protocole de ligne
`I/L/A/T/F` et les actions `check`/`uncheck`/`openTask` ne bougent pas).

## Symptôme (rapporté 2026-11-27)

Volet Windows (flyout natif) : le clic sur une case à cocher d'item ne la
coche plus. La barre d'espace (item focalisé) fonctionne.

## Cause identifiée (vérifiée dans le code + doc Win32, PAS une hypothèse)

`items_list_` est créé avec `LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT`
(`flyout_window.cpp:234-235`, non modifié depuis l'origine). Le commit
`edc6d91` (PR #9, Google Tasks) a AJOUTÉ un bloc `NM_CLICK` entièrement
nouveau (`flyout_window.cpp:810-819`, confirmé par `git log -p -1 edc6d91`
— uniquement des lignes `+`) :

```cpp
} else if (nm->code == NM_CLICK) {
  const auto* click = reinterpret_cast<NMITEMACTIVATE*>(lparam);
  LVHITTESTINFO hit = {};
  hit.pt = click->ptAction;
  const int index = ListView_HitTest(items_list_, &hit);
  if (index >= 0 && index < static_cast<int>(items_.size()) &&
      (hit.flags & LVHT_ONITEMSTATEICON) == 0) {
    Hide();
    SendEvent("openTask", items_[index].id);
  }
}
```

C'est un bug Win32 documenté et croisé sur 3 sources indépendantes :
- Doc Microsoft Learn (Extended List-View Styles, `LVS_EX_CHECKBOXES`) :
  avec `LVS_EX_FULLROWSELECT`, `ListView_HitTest` combine les trois
  sous-drapeaux (`LVHT_ONITEMICON | LVHT_ONITEMLABEL |
  LVHT_ONITEMSTATEICON`) pour **tout** point dans la ligne — `hit.flags`
  porte le bit `LVHT_ONITEMSTATEICON` même pour un clic sur le LABEL, pas
  seulement sur la case.
- StackOverflow #22215253 (réponse acceptée, citant exactement
  `LVS_EX_FULLROWSELECT` + `LVS_EX_CHECKBOXES`) : « hit testing reports
  LVHT_ONITEM … you need to filter out that condition ».
- ReactOS bug CORE-17154 (upstream Wine/comctl32) : « selecting an item
  will prevent the checkbox of that particular item from functioning
  properly … selecting an item also sends LVIS_STATEIMAGEMASK along with
  LVIS_SELECTED which shouldn't happen » — la sélection (tout clic dans la
  ligne, via `FULLROWSELECT`) perturbe le mécanisme NATIF de
  check-au-clic de `LVS_EX_CHECKBOXES`, alors que le chemin clavier
  (barre d'espace sur l'item focalisé) ne passe pas par ce hit-test et
  reste fiable — cohérent avec le symptôme exact rapporté (espace OK,
  clic KO).

Conclusion : s'appuyer sur `LVHT_ONITEMSTATEICON` (natif) pour distinguer
« clic sur la case » de « clic ailleurs », ET s'appuyer sur le
toggle-au-clic natif de `LVS_EX_CHECKBOXES`, est **les deux** rendus non
fiables par `LVS_EX_FULLROWSELECT` dans ce contrôle. Le fix ne doit RIEN
garder de ce mécanisme ambigu côté case à cocher.

## Fix

Le contrôle dessine déjà la case lui-même en owner-draw
(`DrawListItem`, `flyout_window.cpp:574-583` — case à `{rc.left+2,
box_top, rc.left+2+16, box_top+16}`, `box=16`). Le fix bascule le
hit-test de la case sur CETTE géométrie exacte (déterministe, zéro
ambiguïté Win32), au lieu du drapeau natif :

1. **Extraire la géométrie de la case en fonction partagée** — la même
   formule sert au dessin (`DrawListItem`) et au hit-test (`NM_CLICK`) ;
   un seul point de vérité, jamais deux calculs qui peuvent diverger.
   Nouvelle méthode privée (déclarée dans la classe, définie dans le
   `.cpp`) :
   ```cpp
   // Rect exact de la case à cocher dessinée par DrawListItem, pour un
   // item dont le rect ligne (coords client) est `item_rect`. Centrée
   // verticalement, 16px, offset gauche +2 — IDENTIQUE à DrawListItem.
   RECT FlyoutWindow::CheckboxRectFor(const RECT& item_rect) const {
     const int box = 16;
     const int box_top = item_rect.top + (item_rect.bottom - item_rect.top - box) / 2;
     return {item_rect.left + 2, box_top, item_rect.left + 2 + box, box_top + box};
   }
   ```
   `DrawListItem` appelle `CheckboxRectFor(rc)` au lieu de recalculer
   `box`/`box_top`/`brc` en place (suppression des 3 lignes dupliquées,
   remplacées par l'appel — le reste de la fonction, qui utilise déjà
   `brc`, est inchangé).

2. **`NM_CLICK` : hit-test manuel sur le rect réel, bypass du drapeau
   natif `LVHT_ONITEMSTATEICON`** :
   ```cpp
   } else if (nm->code == NM_CLICK) {
     const auto* click = reinterpret_cast<NMITEMACTIVATE*>(lparam);
     LVHITTESTINFO hit = {};
     hit.pt = click->ptAction;
     const int index = ListView_HitTest(items_list_, &hit);
     if (index >= 0 && index < static_cast<int>(items_.size())) {
       RECT item_rect = {};
       ListView_GetItemRect(items_list_, index, &item_rect, LVIR_BOUNDS);
       RECT box = CheckboxRectFor(item_rect);
       if (PtInRect(&box, click->ptAction)) {
         // Clic précis sur la case : toggle manuel, le natif est
         // peu fiable avec LVS_EX_FULLROWSELECT (cf. spec).
         BOOL was_checked = ListView_GetCheckState(items_list_, index);
         ListView_SetCheckState(items_list_, index, !was_checked);
         // ListView_SetCheckState déclenche LVN_ITEMCHANGED → le
         // handler existant (suppress_check_events_, comparaison à
         // items_[index].done) envoie check/uncheck — rien à dupliquer
         // ici.
       } else {
         Hide();
         SendEvent("openTask", items_[index].id);
       }
     }
   }
   ```
   `ListView_GetItemRect(..., LVIR_BOUNDS)` donne le rect ligne en coords
   client — mêmes coords que `dis->rcItem` reçu par `DrawListItem` (both
   client-relative), donc `CheckboxRectFor` produit EXACTEMENT le même
   rect dans les deux appelants.

3. **`LVN_ITEMCHANGED` inchangé** (`flyout_window.cpp:797-809`) — il reste
   le point d'émission unique de `check`/`uncheck` vers Dart, maintenant
   déclenché soit par `ListView_SetCheckState` (clic, via ce fix) soit
   par le toggle natif clavier (barre d'espace, chemin non affecté par
   `LVS_EX_FULLROWSELECT` donc laissé intact). Le garde `(checked !=
   FALSE) != items_[...].done` reste la protection anti-doublon/anti-bruit
   (y compris un éventuel `LVIS_STATEIMAGEMASK` fantôme de simple
   sélection signalé par le bug ReactOS — le garde l'absorbe déjà).

4. **`openTask` ne change pas de condition déclenchante au niveau
   logique produit** — avant le fix, le test `(hit.flags &
   LVHT_ONITEMSTATEICON) == 0` ne déclenchait JAMAIS `openTask` pour un
   clic dans la ligne (le bit est toujours posé avec `FULLROWSELECT`,
   cf. mécanisme ci-dessus) : c'était un second bug silencieux introduit
   par le même commit (la feature "ouvrir la tâche au clic" n'a jamais pu
   se déclencher en v0.6.0). Le fix la restaure au passage (clic hors
   case → `openTask`).

## Hors périmètre

- Dart (`flyout_bridge.dart`, `AppState`) : protocole inchangé,
  `check`/`uncheck`/`openTask` déjà gérés côté Dart (vérifié
  `flyout_bridge.dart:137-146`).
- Pas de nouvelle dépendance, pas de refactor au-delà de l'extraction
  minimale `CheckboxRectFor` (un seul point de vérité pour une géométrie
  partagée dessin/hit-test — nécessaire à la correction, pas un
  nice-to-have).
- Le double-clic (`NM_DBLCLK`) n'est pas géré aujourd'hui et ne le
  devient pas ici (hors périmètre du symptôme rapporté).

## Vérification (pas d'infra de test unitaire C++ Win32 dans ce repo)

Pas de build Windows possible sur la machine de dev Linux (le cross-build
MSVC n'existe pas ici) — la seule compilation réelle du Windows runner se
fait via GitHub Actions (`release-artifacts.yml`, déclenché à la
publication d'un release). Protocole :

1. Revue de source : le diff ne touche que `flyout_window.cpp`
   (`CheckboxRectFor` + `DrawListItem` + le bloc `NM_CLICK`) ; `grep -c
   LVHT_ONITEMSTATEICON flyout_window.cpp` → 0 après le fix (plus aucune
   dépendance au drapeau natif ambigu).
2. Tag `v0.6.1` sur le commit du fix → `release-artifacts.yml` compile
   réellement le `.cpp` sous MSVC (Windows runner GitHub) : un verdict
   de compilation (succès/échec) est la première preuve, avant même le
   retest utilisateur.
3. Retest device (utilisateur, sur son poste Windows) : installer le zip
   `v0.6.1`, ouvrir le volet, cliquer sur la case d'un item non coché →
   coché immédiatement (sans fermer le volet) ; cliquer la case d'un item
   coché → décoché ; cliquer le LABEL d'un item (hors case) → le volet se
   ferme et l'app s'ouvre sur la tâche (`openTask`, comportement restauré
   par le même fix — à signaler comme nouveau comportement visible, pas
   un bug).

## Release 0.6.1 (bundlée avec ce fix)

- `server/VERSION` : 0.6.0 → 0.6.1 (cohérence avec le tag ; évite un faux
  « mise à jour serveur requise » dès la publication du release, pour
  l'utilisateur qui rebuild son serveur de staging au même moment que le
  client).
- Pas de bump `app/pubspec.yaml` (`version: 0.1.0` n'est jamais lu pour
  l'`APP_VERSION` — `release-artifacts.yml` l'injecte depuis le tag git,
  `${GITHUB_REF_NAME#v}`, vérifié ligne 36/73 du workflow).
- Notes de release : « Fix : le volet Windows ne cochait plus les items
  au clic (seule la barre d'espace fonctionnait) — régression de la
  fonctionnalité Google Tasks (clic pour ouvrir la tâche) introduite en
  0.6.0. » + mention de VERSION serveur alignée.

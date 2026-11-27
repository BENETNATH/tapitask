# Spec 2026-11-27c — Fix volet Windows : 2 bugs visuels (resize + chips actifs)

**Statut** : à implémenter (bugfix 0.6.1, groupé avec
`2026-11-27-flyout-click-fix.md`).
**Périmètre** : `app/windows/runner/flyout_window.cpp` +
`flyout_window.h` UNIQUEMENT. Zéro changement Dart.

## Bug A — redimensionnement horizontal : l'icône « ouvrir l'app » disparaît

**Rapporté** (capture utilisateur) : en élargissant/rétrécissant le volet
horizontalement, l'icône d'ouverture de l'app (entre le titre et la
croix de fermeture) se retrouve coupée/fantôme (fragment visible,
glyphe tronqué).

**Cause identifiée (vérifiée dans le code)** : `flyout_window.cpp:120-128`
— la classe de fenêtre (`WNDCLASS wc = {}`) ne fixe JAMAIS `wc.style`
(reste à `0` par défaut). Sans `CS_HREDRAW | CS_VREDRAW`, Win32
n'invalide PAS automatiquement l'intégralité du client lors d'un
redimensionnement (horizontal notamment) — seules les zones
« nouvellement exposées » (agrandissement) sont repeintes d'office ; au
rétrécissement, rien ne force le système à repeindre la zone que les
contrôles déplacés (`pin_btn_`, `open_btn_`, `close_btn_`, `title_` —
tous repositionnés par `Layout()` à chaque `WM_SIZE`, `flyout_window.cpp:
741-747`) viennent de quitter. Résultat : des pixels de l'ancien état
(glyphe à l'ancienne position, plus large) restent visibles en
surimpression — c'est un défaut Win32 documenté et une pratique standard
(toute fenêtre avec des enfants repositionnés dynamiquement en
redimensionnement doit poser `CS_HREDRAW | CS_VREDRAW`).

**Fix** (1 ligne, chirurgical) :
```cpp
WNDCLASS wc = {};
wc.style = CS_HREDRAW | CS_VREDRAW;   // <-- ajout : force l'invalidate
                                       //     complet du client à chaque
                                       //     resize (évite les fantômes
                                       //     de pin/open/close/title
                                       //     repositionnés par Layout()).
wc.lpfnWndProc = &FlyoutWindow::WndProc;
```
(`flyout_window.cpp:120`, juste après `WNDCLASS wc = {};` et avant les
autres affectations — ordre indifférent, regrouper avec les autres
`wc.*=` est le plus lisible.)

## Bug B — bascule de liste (chip « maison »/« pro ») : couleur/forme pas mise à jour

**Rapporté** (capture utilisateur) : en passant d'une liste à l'autre
(tap sur un chip), la couleur/forme indiquant la liste ACTIVE ne se met
pas à jour correctement — glitch visuel (capture : « pro » apparaît
rendu avec le même style plein que « maison », alors qu'une seule liste
doit porter le style actif).

**Cause identifiée (vérifiée dans le code)** :
`RebuildChips(int width)` (`flyout_window.cpp:380-431`) calcule une
signature `sig` UNIQUEMENT à partir des **ids** de `lists_` (ligne
384-390) — PAS de `active_`. Ligne 391 :
```cpp
if (width == last_chip_width_ && sig == last_chip_sig_) return;
```
Quand l'utilisateur tape un chip, `UpdateData` reçoit une nouvelle ligne
`A\t<id>` (même jeu de listes, même largeur) → `active_` change mais
`sig`/`width` sont IDENTIQUES → retour anticipé ligne 391, **sans jamais
invalider les boutons chip existants**. Les chips sont owner-draw
(`BS_OWNERDRAW`, dessinés par `DrawChip` qui lit `active_` au moment du
`WM_DRAWITEM`) — sans invalidation explicite, Windows ne redessine PAS
le chip tant qu'un autre évènement (resize, survol, fenêtre
recouverte/découverte) ne le force ; le changement d'état actif reste
visuellement « en attente », d'où l'incohérence rapportée.

**Fix** (surveiller aussi `active_`, invalider sans détruire/recréer) :

1. Nouveau champ privé dans `flyout_window.h`, à côté de
   `last_chip_width_`/`last_chip_sig_` :
   ```cpp
   std::string last_chip_active_;
   ```
2. Dans `RebuildChips`, avant le `return` anticipé de la ligne 391,
   détecter un changement de `active_` seul (sig/width inchangés) et
   invalider les chips existants sans les reconstruire :
   ```cpp
   if (width == last_chip_width_ && sig == last_chip_sig_) {
     if (active_ != last_chip_active_) {
       last_chip_active_ = active_;
       for (HWND chip : chips_) InvalidateRect(chip, nullptr, TRUE);
     }
     return;
   }
   ```
3. À la fin de la fonction (après la reconstruction complète, juste
   avant le `return` implicite / à la fin du corps, y compris le chemin
   `lists_.size() <= 1` qui retourne tôt ligne 402) : poser
   `last_chip_active_ = active_;` pour que le prochain appel avec le
   MÊME état actif ne redéclenche pas d'invalidation inutile. Concrètement :
   - juste après `if (lists_.size() <= 1) { chips_rows_ = 0; return; }`
     devient `if (lists_.size() <= 1) { chips_rows_ = 0;
     last_chip_active_ = active_; return; }` ;
   - à la toute fin de la fonction (après la boucle de création des
     chips), ajouter `last_chip_active_ = active_;` avant le `}` fermant.

## Hors périmètre

- Dart : aucun changement, le protocole `A\t<id>` est inchangé.
- Pas de refactor du reste de `DrawChip`/`RebuildChips`.
- Le Bug A (`CS_HREDRAW|CS_VREDRAW`) est une fenêtre TOP-LEVEL unique
  enregistrée une seule fois (`RegisterClass`, pas par-instance) — le
  fix s'applique à toutes les instances du volet, pas de risque de
  double-registration (vérifier qu'aucun second `RegisterClass` du même
  `kClassName` n'existe ailleurs dans le fichier avant de conclure — si
  c'est le cas, l'unique point d'enregistrement suffit).

## Vérification (idem click-fix : pas de toolchain Windows ici)

1. Revue de source : diff limité à `wc.style = CS_HREDRAW |
   CS_VREDRAW;` (Bug A) + `last_chip_active_` (déclaration header + 3
   points d'usage dans `RebuildChips`, Bug B).
2. Le même tag `v0.6.1` (groupé avec le fix du clic) déclenche la
   compilation MSVC réelle via `release-artifacts.yml` — premier
   verdict de compilation.
3. Retest device (utilisateur) :
   - Bug A : agrandir/rétrécir le volet horizontalement plusieurs fois
     de suite → l'icône d'ouverture de l'app reste nette, jamais
     tronquée/fantôme, à toutes les largeurs.
   - Bug B : avec ≥ 2 listes, taper alternativement sur chaque chip →
     la liste active change de style (plein/coloré) immédiatement à
     chaque tap, l'autre repasse en style inactif sans retard ni
     fantôme.

# Lot G — Windows (code mort) + icône d'échéance (emoji → Icon)

Date : 2026-11-17
Statut : spec prête pour implémentation
APK : rebuild requis après ce lot (retest device)

## G1 — « la partie Windows » : supprimer le code mort `lib/ui/tray_panel.dart`

Les 7 issues `flutter analyze` (lot F) viennent toutes de ce fichier :
import de `package:desktop_multi_window`, absente du `pubspec.yaml`
(package non résolue) + `flutter/material.dart` déprécié + 4
`DesktopMultiWindow` undefined.

`tray_panel.dart` (217 lignes, `TrayPanel`) n'est importé par RIEN
( vérifié : aucun usage de `TrayPanel`/`tray_panel` hors du fichier).
C'est un premier jet abandonné du volet rapide, remplacé par le flyout
nativement Win32 :
- `windows/runner/flyout_window.cpp` (771 lignes, intact)
- `lib/platform/flyout_bridge.dart` (MethodChannel `tapitask/win32`)
- `lib/platform/tray_controller.dart` (tray_manager + window_manager,
  les deux dans le pubspec)

Fix : supprimer `lib/ui/tray_panel.dart`. Aucune nouvelle dépendance,
aucun autre fichier touché. `flutter analyze` → 0 issue.

## G2 — Icône d'échéance rendue en glyphe manquant (losange noir + « ? »)

Screenshot device 2026-11-17 : sur les items avec échéance, l'« icône »
avant la date est un losange noir à point d'interrogation = pictogramme
manquant. Cause : `_itemSubtitle` (list_screen.dart:726) met des EMOJIS
dans le texte :

    overdue ? "⚠ " : "📅 " + _dueLabel(...)   // ligne 731
    "↻ " + _recurrenceLabel(...)              // ligne 739
    "📝 " + notes                             // ligne 743

Les emojis ne sont pas garantis rendus sur tous les devices (police
emoji absente/limitée) → glyphe manquant. Les `Icon` Material du reste
de l'app (Icons.event dans l'IconButton de la ligne, etc.) rendent
parfaitement : la police MaterialIcons est embarquée
(`uses-material-design: true`).

Fix : remplacer les emojis par des `Icon` (police embarquée, tous
plateformes), taille 12 :
- échéance à venir : `Icons.event` (même icône que l'IconButton de la
  ligne — cohérence)
- échéance dépassée : `Icons.warning_amber_rounded` (couleur `error`
  conservée sur icône + texte)
- récurrence : `Icons.replay`
- note : `Icons.notes_outlined` (même icône que l'action « Note » de la
  bottom sheet)

Implémentation : helper `_subtitlePart(IconData icon, String text,
{Color? color})` = `Row(mainAxisSize: min, [Icon(size 12, color),
SizedBox(width: 3), Text(size 12, color)])`. `_itemSubtitle` construit
ses parties via ce helper.

Également : `s.dart` `compactDueHelp` contient le même emoji
- fr (ligne 155) : `Badge 📅 sur les items du volet` →
  `Badge d'échéance sur les items du volet`
- en (ligne 346) : `📅 badge on flyout items` →
  `Due-date badge on flyout items`

Le `✔` (U+2714) des autres chaînes l10n est CONSERVÉ : glyphe texte
standard présent dans toutes les polices système.

## Tests (Dart, TDD — flutter test)

Nouveau `app/test/list_screen_due_icon_test.dart` :

1. **sous-titre sans emoji + icônes présentes** : item avec
   `dueDate` future + `recurrence: "daily"` + `notes` → pump ListScreen
   → `find.textContaining("📅")` / `"↻"` / `"📝"` = findsNothing ;
   `Icon(Icons.event)`, `Icon(Icons.replay)`,
   `Icon(Icons.notes_outlined)` = findsOneWidget ; le libellé de date
   (dd/MM) est visible.
2. **échéance dépassée** : item `dueDate` hier →
   `Icon(Icons.warning_amber_rounded)` = findsOneWidget, aucun `"⚠ "`
   dans le texte.

Setup : `AppDb.forTesting(NativeDatabase.memory())`,
`AppState(db: db)` avec `state.settings["due_dates"] = true`
(featureDueDates), `db.upsertList` + `db.addItem`, pump ListScreen
(comme le test overflow). Rappels : les 26 tests existants (dont les 2
du lot F) doivent rester verts. Pas de nouvelle dépendance.

## Vérification

- `flutter analyze` → **0 issue** (les 7 de tray_panel disparaissent,
  aucun ajout).
- `flutter test` → 26 + 2 nouveaux, tous verts.
- Rebuild APK debug ; retest device : sous-titre d'item avec échéance
  → icône propre, plus de losange.

## Hors périmètre

- Flyout Win32 natif (`flyout_window.cpp`) : intact, pas de change.
- Le flyout natif n'utilise pas d'emoji (`dueSuffix` = texte propre) :
  rien à changer côté native.

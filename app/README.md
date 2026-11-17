# Tapitask — App Flutter

App de gestion de tâches **offline-first** : SQLite local comme source de vérité,
synchronisation incrémentale (delta) avec le serveur `../server`, WebSocket push.

Cibles fonctionnelles : **Windows** (tray + volet rapide) et **Android**
(widgets d'écran d'accueil). Le build web échoue à ce stade (persistance locale
drift/`dart:ffi` non disponible sur web) — le web reste une cible à venir.

## Prérequis

- Flutter SDK récent
- Pour Windows : Visual Studio Build Tools (charge de travail C++ desktop)
- Pour Android : Android SDK

```bash
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d windows     # ou -d android
```

## Fonctionnalités

- **Offline-first** : chaque action (créer, cocher, éditer, supprimer) est appliquée
  immédiatement au SQLite local, puis synchronisée en arrière-plan (delta par curseur
  `since`, last-write-wins).
- **Listes & items** : couleurs, épinglage, tri (alpha / manuel / par liste), sous-tâches,
  échéances, notes, assignés, duplication.
- **Vues transverses** : « Aujourd'hui » (items dus ou en retard, toutes listes) et
  « À faire » (items non cochés groupés par liste).
- **Réglages par utilisateur** (synchronisés) : activation/désactivation de fonctions
  (échéances, poubelle…), thème clair/sombre.
- **Ajout rapide** : multi-lignes (1 ligne = 1 item), parseur de dates (« demain »,
  « vendredi »…), mots-clés d'échéance personnels (« j+7 » → +7 jours), `#liste`.
- **Auth** : login (email + mot de passe), refresh token, 2FA TOTP, invite par code,
  URL serveur configurable.
- **Partage** : bouton « Partager » sur une liste → code d'invitation, email avec rôle
  viewer/editor, membres, retrait.
- **Windows** : icône systray, volet rapide ancré près de la systray (Win32 natif),
  ajout rapide, listes épinglées en chips, épingle « toujours visible ».
- **Android** : widgets d'écran d'accueil (voir plus bas).

## Widgets Android

Les deux providers sont **livrés dans le dépôt**
(`app/android/app/src/main/kotlin/com/tapitask/tapitask/`) — plus rien à copier :

- **« Tapitask »** (`ListWidgetProvider`) : liste cochable, taille **2×2 par défaut**
  (redimensionnable), ◀▶ pour changer de liste, couleur par liste, bouton ＋,
  bouton « Ouvrir » en icône. Le cochage fait dans le widget est appliqué dans
  l'app au retour au premier plan.
- **« Ajout rapide »** (`QuickAddWidgetProvider`) : 1×1, ouvre l'app directement sur
  la liste active du widget avec le champ d'ajout focalisé.

Les layouts sont dans `app/android/app/src/main/res/layout/`
(`list_widget.xml`, `quickadd_widget.xml`), les infos dans `res/xml/`.

Le widget lit les données posées par `HomeWidgetService` (prefs partagées — cache
local, fonctionne hors ligne) et se rafraîchit après chaque synchro / toggle / ajout.

## Tray Windows

- **Icône systray** (plugin `tray_manager`) : livrée dans les assets, rien à copier.
  - Clic gauche : toggle du volet rapide.
  - Clic droit : menu (Ouvrir, Quitter).
- **Volet rapide** : fenêtre **Win32 native** (`windows/runner/flyout_window.cpp`)
  ancrée près de l'icône tray : `WS_EX_TOOLWINDOW` (pas de taskbar), position ancrée,
  `SetWindowPos` au clic tray, focus, resize + move persistés.
  - Contenu Flutter : `TrayPanel` (ajout rapide multi-lignes en bas, listes épinglées
    en chips, épingle « toujours visible », fermeture = cacher, l'app reste en fond).
  - Le contenu est construit une seule fois et ré-attaché via `setState` pour conserver
    l'état entre ouvertures/fermetures.
- **Note** : le `WM_DPICHANGED` est ignoré (fixe 96 DPI) pour rester simple.

## Architecture

```
lib/
├── main.dart               # bootstrap, observers (resume → sync/toggles), providers
├── app.dart                # MaterialApp, thème, routes
├── l10n/                   # localisation (fr/en)
├── models/                 # List, Item, Subtask (entités métier)
├── state/                  # AppController + AppService (actions, synchro, widgets)
├── data/
│   ├── database.dart       # base locale Drift/SQLite
│   ├── api_client.dart     # HTTP + JWT + refresh automatique
│   └── sync_service.dart   # synchro delta + WebSocket
├── ui/
│   ├── home_screen.dart    # liste des listes + vues transverses
│   ├── list_screen.dart    # écran d'une liste (items, échéances, notes)
│   ├── today_screen.dart   # « Aujourd'hui » : dus / en retard, toutes listes
│   ├── todo_all_screen.dart# « À faire » : non cochés groupés par liste
│   ├── settings_screen.dart# réglages par utilisateur + thème
│   ├── login_screen.dart   # login / invite / URL serveur
│   ├── widgets.dart        # widgets partagés (tile, icône d'échéance…)
│   └── tray_panel.dart     # contenu du volet rapide (Windows)
├── widgets/
│   └── home_widget.dart    # bridge Dart ↔ natif (prefs partagées, toggles)
├── platform/
│   ├── tray_controller.dart# icône systray + menu
│   └── flyout_bridge.dart  # channel natif → volet Win32
├── utils/
│   ├── date_parser.dart    # « demain », « vendredi », j+N
│   ├── repeat_parser.dart  # récurrences
│   └── due_keywords.dart   # mots-clés d'échéance personnels
└── theme/                  # thèmes clair/sombre
```

### Natif

```
android/app/src/main/kotlin/com/tapitask/tapitask/
├── ListWidgetProvider.kt       # widget liste 2×2 (cochage, ◀▶, couleur, deep-link)
├── QuickAddWidgetProvider.kt   # widget 1×1 (deep-link liste active + focus)
└── TapitaskActions.kt          # actions communes
windows/runner/flyout_window.cpp  # volet rapide Win32 (C++)
```

Chaque action est **appliquée d'abord en local** (SQLite) et notifiée immédiatement
à l'UI ; la synchro serveur part en arrière-plan — c'est ce qui rend l'app instantanée.

## Tests

31 tests Dart couvrant synchro, parseurs, widget intent/toggles, deep-link ＋,
icône d'échéance, overflow du titre de liste, lancement du widget.

```bash
# Prérequis système (Linux) : les plugins tray desktop déclenchent un build
# d'assets natifs (GTK 3, X11, Xi) + Clang :
#   sudo apt install libgtk-3-dev libx11-dev libxi-dev clang
flutter test
```

## Build & signature Android

```bash
flutter build apk --release    # ou --debug
flutter build windows --release
```

Si `android/app/key.properties` existe (créé par les scripts de build),
`build.gradle.kts` signe en release avec le keystore `tapitask-release.jks`
(gitignored, avec `key.properties`) : gardez-le pour que les mises à jour
s'installent par-dessus l'ancienne version.

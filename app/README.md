# Tapitask — App Flutter

Client offline-first : Windows (systray + volet rapide), Android (widgets d'écran d'accueil), Web.
SQLite local comme source de vérité, synchronisation incrémentale (delta) avec le serveur
`../server`, WebSocket push.

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

## Configurer Google Tasks sur Android

1. Activez l’API Google Tasks dans le projet Google Cloud de Tapitask. [Console Google Cloud](https://console.cloud.google.com/apis/library/tasks.googleapis.com)
2. Configurez l’audience et le consentement OAuth, puis ajoutez le scope `https://www.googleapis.com/auth/tasks` dans **Data Access**. En mode **Testing**, ajoutez les comptes des testeurs. Pour une diffusion publique, suivez la procédure de Google. [Vérification OAuth](https://support.google.com/cloud/answer/13464321)
3. Dans **Clients**, créez un client OAuth Android pour `com.tapitask.tapitask` avec le SHA-1 du certificat qui signe l’APK distribué. Pour un APK de développement, enregistrez également le SHA-1 du certificat debug (`./gradlew :app:signingReport` depuis `app/android`). [Configuration OAuth Android](https://developer.android.com/identity/authorization#set-up-your-google-cloud-console-project)

Le SHA-1 vérifié sur l’APK officiel v0.5.0 est `F4:E5:AA:41:09:7E:8B:1A:E1:38:AE:C0:07:77:05:A9:8F:CD:DB:DB`.

L’envoi crée des copies avec le titre, les notes, le jour d’échéance et l’état coché. Les sous-tâches sont copiées comme tâches indépendantes. Un nouvel envoi crée de nouvelles copies.

Lorsqu’une heure est définie, Tapitask l’ajoute aux notes de la copie si la place le permet. Pour la programmer dans Google Tasks, choisissez l’heure dans l’application Google Tasks.

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
- Sur **Android**, faites un appui long sur une tâche pour l’envoyer vers Google
  Tasks. Le menu ⋮ d'une liste permet d'envoyer toutes ses tâches à faire.
  Choisissez la liste Google de destination et confirmez l'envoi.
- **Importer depuis Google Tasks** dans le menu ⋮ copie les tâches de la liste Google choisie, y compris les tâches terminées, les notes, les liens et les jours d’échéance. Relancer le même import ajoute uniquement les tâches inédites dans la liste Tapitask.
- Touchez le titre d’une tâche pour afficher ses détails, modifier ses notes ou ouvrir un lien. La case coche la tâche. Les tâches terminées sont barrées et regroupées en bas de la liste. Le menu ⋮ permet de les masquer.
- Ouvrez **Calendrier** depuis l’accueil pour afficher un mois, une semaine ou un à quatre jours. Les filtres affichent les tâches planifiées, terminées ou les deux. Le calendrier utilise la date de fin enregistrée ou, pour les anciennes tâches terminées, leur échéance si elle existe.
- Une échéance est définie pour la journée. Rouvrez le sélecteur et choisissez **Ajouter une heure** pour préciser l’heure. La synchronisation des jours d’échéance nécessite la mise à jour du serveur.
- **Export / Import** : menu « Exporter / Importer » sur une liste (JSON, Markdown
  Obsidian, CSV) + export global (Tout exporter JSON/CSV) et import dans les réglages.
  L'import (JSON ou Markdown) crée toujours de **nouvelles** listes (jamais de merge).
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

Le widget lit les données posées par `WidgetService` (prefs partagées — cache
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
├── main.dart               # bootstrap, thème, observers (resume → sync/toggles), routes
├── l10n/s.dart             # localisation (fr/en)
├── state/
│   ├── app_state.dart      # AppState : actions, synchro, widgets, parseur de dates/j+N
│   └── widget_intent.dart  # deep-link widget → app
├── data/
│   ├── database.dart       # base locale Drift/SQLite (LocalLists / LocalItems)
│   ├── api_client.dart     # HTTP + JWT + refresh automatique + export/import (corps brut)
│   ├── sync_service.dart   # synchro delta + WebSocket
│   ├── connection/         # ouverture de la DB : native / web (WASM) / unsupported
│   └── update_service.dart # in-app update (+ android_updater, windows_updater, app_version)
├── ui/
│   ├── home_screen.dart    # liste des listes + vues transverses
│   ├── list_screen.dart    # écran d'une liste (items, échéances, notes, menu Exporter/Importer)
│   ├── today_screen.dart   # « Aujourd'hui » : dus / en retard, toutes listes
│   ├── todo_all_screen.dart# « À faire » : non cochés groupés par liste
│   ├── search_screen.dart  # recherche
│   ├── settings_screen.dart# réglages + export/import global
│   ├── share_screen.dart   # partage (invitations, membres, rôles)
│   ├── admin_screen.dart   # admin (comptes, audit)
│   ├── login_screen.dart   # login / invite / URL serveur
│   └── list_dialogs / due_picker / due_format / update_dialog
├── platform/
│   ├── tray_controller.dart# icône systray + menu (+ tray_controller_web : no-op)
│   ├── flyout_bridge.dart  # channel natif → volet Win32
│   ├── widget_service.dart # bridge Dart ↔ natif Android (prefs partagées, toggles)
│   ├── file_service.dart   # export/import de fichiers (dialog natif, web inclus)
│   └── update_opener_*     # ouvrir le store / le téléchargement (update)
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

139 tests Dart couvrant synchro, parseurs, widgets, export/import, update,
partage, admin/audit, deep-link, icône d'échéance, lancement du widget.

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

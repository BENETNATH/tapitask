# Spec : runbook migration serveur, bootstrap de MAJ in-app, badge de délai en gras

Date : 2026-11-22 — Statut : validée

## Contexte

Trois besoins posés après la release v0.3.0 : (A) la montée de version majeure
Postgres de la prod s'est faite en procédurier (dump/restore) sans rien de
documenté — il faut un process réutilisable ; (B) l'app ne sait pas se mettre à
jour (pubspec en 0.1.0, aucune détection de release, aucune version du serveur
exposée) ; (C) le badge de délai (surcharge « • en retard » / « demain ») est
invisible sur le widget Android (tronqué par ellipsize) et buggé sur le volet
Windows (puce doublée) — l'utilisateur veut du texte en gras à la place de
l'icône.

## Périmètre

- §A : runbook de migration serveur (Postgres majeur), document `docs/ops/`.
- §B : bootstrap de mise à jour in-app — endpoint de version serveur,
  injection de version client, vérification GitHub + serveur, MAJ Windows
  (zip + self-replace), MAJ Android (APK + intent d'installation), ligne
  « Mises à jour » dans les réglages, indicateur « mise à jour serveur
  requise ».
- §C : badge de délai rendu en gras sur le widget Android et le volet Windows,
  avec correction de la puce doublée.
- Hors périmètre (listé en bas) : l'UI app (Dart) du badge, le web, les
  notifications push, Play Store, MSIX, Squirrel.

## Maquettes

Pas de changement visuel app (Dart) — widget et volet native : pas de
maquette Flutter ; le §C est specifié en layout XML + rendu Win32 précis.

## §A — Runbook de migration serveur

`docs/ops/server-migration.md`, documentant le process réellement exécuté sur
la prod tapitask le 2026-11-22 (PG16 → PG19). Contenu obligatoire :

- **Pourquoi dump/restore et pas upgrade in-place** : depuis les images
  Docker Postgres 18+, le data-dir vit dans une sous-dossier par version
  majeure (layout pg_ctlcluster) ; l'entrypoint refuse un volume initialisé
  par une version antérieure (« appears to be PostgreSQL data in
  /var/lib/postgresql »). `pg_upgrade` in-place n'est pas faisable à travers
  un mount de volume sans les deux versions côte à côte.
- **Étapes** (dans cet ordre) :
  1. Deux backups avant toute opération : `pg_dumpall` (SQL, extracté du
     conteneur, nettoyé des lignes pg_ctl) + tar intégral du data-dir. Les
     backups sortent du volume Docker (exfiltration autorisée, dossier dédié,
     compteurs de contrôle notés).
  2. Arrêt API (`docker compose stop api`) — puis, si le restore exige un
     DROP, `pg_terminate_backend(pid)` sur les connexions actives restantes.
  3. Volume neuf (le layout 18+ exige un mount unique à la racine ; le volume
     ancien est supprimé APRÈS les deux backups).
  4. `docker compose up -d db` → healthy, puis restore du dump.
  5. **Le schéma est créé par l'application au boot** : pas d'alembic. Si
     l'API a démarré avant le restore, les tables/FK existent déjà → le COPY
     échoue en cascade et la base est polluée. Remède : `pg_terminate_backend`
     + DROP DATABASE + CREATE + re-restore propre (pas de « fix » partiel).
  6. Vérification par compteurs table par table (comparer au fichier de
     compteurs pris à l'étape 1 : items, list_members, lists,
     refresh_tokens, users, webhooks) — identique = restore OK.
  7. Smoke : API 302 (redirect login), 401 sans auth, aucun 500 dans les
     logs, un worker visible (`/proc` : 1 seul uvicorn worker — le hub WS est
     in-process).
- **Pièges notés** : fenêtre de consentement sur les opérations destructives
  (5 min, à anticiper) ; le conteneur PG19 refuse le volume PG16 dès le boot
  (restart loop) — c'est le signal, pas un crash.
- Général : le process s'applique à toute montée majeure de Postgres de ce
  projet (et, mutatis mutandis, à n'importe quelle stack compose du même
  type).

Règles de test du §A (document) : R-A1 — le fichier existe dans
`docs/ops/`, référence les deux commandes exactes de backup, l'ordre
backup→stop→volume→restore→compteurs→smoke est respecté, et le piège
« schéma créé au boot » est documenté avec son remède. (Test = lecture du
fichier : grep des marqueurs dans le document.)

## §B — Bootstrap de mise à jour in-app

Faites vérifiés dans le code (2026-11-22) :

- Client : `app/pubspec.yaml` version `0.1.0` (jamais bumpé par les
  releases) ; `http: ^1.2.2` déjà en dépendance ; `ApiClient`
  (`app/lib/data/api_client.dart:13`) porte le `baseUrl` serveur et persiste
  `server_url` dans les prefs ; le workflow `.github/workflows/
  release-artifacts.yml` build Windows + APK **sans** `--dart-define` ;
  l'UI réglages (`app/lib/ui/settings_screen.dart`) compose des lignes via
  `_tapRow(title, value, onTap)` (ligne 78) dans un `ListView` (ligne 272).
- Serveur : `server/app/main.py` monte les routeurs par `app.include_router`
  (lignes 52-56), CORS via `settings.CORS_ORIGINS` (lignes 37-38) ; aucun
  endpoint de version ; le serveur ne porte aucune version lisible (pas de
  fichier, pas de constant).
- Android : `AndroidManifest.xml` a INTERNET + POST_NOTIFICATIONS,
  **pas** de `REQUEST_INSTALL_PACKAGES`, pas de `<provider>` FileProvider ;
  `MainActivity.kt` est dans
  `app/android/app/src/main/kotlin/com/tapitask/tapitask/`.

### §B.1 — Version côté serveur

- `server/VERSION` : fichier texte d'une ligne (`0.3.0`), dans le repo,
  bumpé à chaque release par le même commit que le tag.
- `GET /version` (public, sans auth) → `{"version": "<contenu du fichier>"}`.
  Le fichier est lu à l'import du module (une seule lecture), pas à chaque
  request.
- R-B1 : `GET /version` répond 200 `{"version": "0.3.0"}` (valeur = contenu
  du fichier de test) **sans** token ; un test existant de l'API (route
  arbitraire protégée) reste 401 — l'endpoint n'a pas percé l'auth globale.
- R-B2 : si `server/VERSION` est absent/corrompu, l'endpoint répond 200 avec
  `{"version": "unknown"}` (pas de 500).

### §B.2 — Version côté client + injection

- `app/lib/data/app_version.dart` (ou équivalent) :
  `const String appVersion = String.fromEnvironment('APP_VERSION',
  defaultValue: 'dev')`.
- `release-artifacts.yml` : les deux steps de build (Windows + Android)
  gagnent `--dart-define=APP_VERSION=${GITHUB_REF_NAME#v}` (la référence du
  run = le tag du release).
- R-B3 : un test Dart vérifie que `String.fromEnvironment` est la source
  (ex. un test qui lit la constante avec un `--dart-define` simulé n'existant
  pas → 'dev' ; ou un test de parsing de `v0.3.0` → `0.3.0`). L'essentiel :
  le code qui compare les versions consomme `appVersion`, pas le pubspec.

### §B.3 — Service de vérification (`update_service.dart`)

- `checkForUpdates({required http.Client client, required ApiClient api})` :
  1. `GET https://api.github.com/repos/BENETNATH/tapitask/releases/latest`
     → `tag_name` (ex. `v0.3.0`), `body` (notes), `assets[]` (nom +
     `browser_download_url`). Asset Windows = `*-windows-x64.zip`, asset APK
     = `*-android.apk` (par motif de nom, pas par ordre).
  2. Version serveur : `GET {baseUrl}/version` → `{"version": …}`.
  3. Résultat : `UpdateInfo { clientAvailable, latest, clientCurrent,
     notes, windowsUrl, apkUrl, serverRequired, serverVersion }`.
     `clientAvailable = latest > clientCurrent` (comparaison semver minimale
     sur le tuple numérique, **sans** nouvelle dépendance ; `v0.3.0` →
     `(0,3,0)`, préfixe `v` toléré des deux côtés).
     `serverRequired = latest > serverVersion`.
- Appelé au démarrage (fond, sans UI bloquante) et depuis la ligne réglages.
- Échec réseau / endpoint absent → `UpdateInfo` neutre (disponible=false,
  serverRequired=false), l'app ne s'encombre pas ; un essai de version
  serveur en échec ne masque pas la partie GitHub.
- R-B4 (tests unitaires, fake http.Client) : payload GitHub réel (tag
  `v0.4.0`, 2 assets + un `.dmg` parasite) → urls correctes, notes parsées ;
  `clientCurrent=0.3.0`/`latest=0.4.0` → `clientAvailable=true` ;
  `0.4.0`/`0.4.0` → false ; `0.3.10` > `0.3.9` (le piège lexicographique) ;
  serveur `0.2.0` vs latest `0.3.0` → `serverRequired=true`, notes
  préservées ; GitHub 403 (rate limit) → neutre, serveur toujours évalué.

### §B.4 — UI réglages « Mises à jour »

- Nouvelle ligne dans le `ListView` des réglages : titre « Mises à jour /
  Updates », valeur = `appVersion` ; tap → `showDialog` compact :
  - « App {appVersion} » + (si dispo) « {latest} disponible — {notes} » +
    bouton « Mettre à jour » (Windows : §B.5 ; Android : §B.6 ; web : ouvrir
    l'URL du release via `url_launcher`… **pas de nouvelle dépendance : sur
    web, le bouton ouvre la page release via un lien cliquable, sans
    package** — un `Text.rich` avec `TextSpan` clickable suffit).
  - « Serveur {serverVersion} » + (si requis) « mise à jour serveur
    requise » (texte, pas d'action — le serveur se met à jour sur l'infra,
    pas dans l'app).
- I18n : clés FR + EN dans `app/lib/l10n/s.dart` comme les autres.
- R-B5 (widget test) : avec un `UpdateInfo` injecté (dispo + serveur
  requis), le dialog affiche les deux versions, le bouton, et le texte
  « mise à jour serveur requise » ; sans dispo → pas de bouton, pas de
  texte de serveur.

### §B.5 — Self-update Windows

- Télécharger le zip (HttpClient `http` existant, stream → fichier temporaire
  à côté du répertoire de l'app, `path_provider` déjà présent).
- Décompresser : **une seule nouvelle dépendance autorisée** : `archive`
  (pure Dart) — documentée ici comme la justification unique.
- Self-replace (un exe Windows ne peut pas être remplacé en cours
  d'exécution) : l'app écrit dans `<appdir>\update-tmp\` le contenu du zip
  (dossier `Release\` → son contenu, pas le wrapper) + un `run_update.bat` :
  attendre la fin de `tapitask.exe` (boucle `tasklist`), `xcopy /E /Y /I`
  `update-tmp\*` → `<appdir>\`, supprimer le tmp, `start "" tapitask.exe`,
  s'effacer. L'app lance le bat détaché puis `exit(0)`.
- Si le téléchargement/le dépatch échoue : message d'erreur dans le dialog,
  rien n'est modifié (l'ancienne version reste intacte tant que le bat n'a
  pas tourné).
- R-B6 (tests unitaires) : le contenu du bat généré contient l'attente du
  process, l'xcopy vers le bon chemin, le relancement ; la décomposition du
  zip (fake `archive.Archive`) produit le contenu de `Release\` à la racine
  de `update-tmp\`, pas le dossier wrapper ni les fichiers `.vcxproj`.
- **Contrainte de vérification** : pas de toolchain Windows sur la machine
  de dev Linux — le code Win32 (bat) est vérifié par tests unitaires du
  Dart qui le génère + build de release suivant (workflow `release-artifacts`
  compile le runner C++ ; un régress de compilation est visible à la
  release) + test device utilisateur. Pas de `flutter build windows` au
  gate local.

### §B.6 — Mise à jour Android (APK)

- Télécharger l'APK dans le cache app.
- MethodChannel `com.tapitask/tapitask/updater` → `MainActivity.kt` :
  `FileProvider` (nouveau `<provider>` dans le manifest + `res/xml/
  file_paths.xml`) → `Intent(ACTION_VIEW)` type
  `application/vnd.android.package-archive` + `FLAG_GRANT_READ_URI_PERMISSION`.
- Manifest : `android.permission.REQUEST_INSTALL_PACKAGES`. (L'utilisateur
  autorise une fois « installer des apps inconnues » pour Tapitask — prompt
  système, pas de notre côté.)
- R-B7 : pas de test unitaire Kotlin (pas d'infra) — preuve par compilation
  (`flutter build apk --debug` vert) + lecture de la source manifest
  (permission + provider présents) + retest device utilisateur.

### §B.7 — Gates §B

- Suite Dart complète (`flutter test`) ; `flutter analyze` ;
  `flutter build apk --debug` vert ; suite serveur (`server/.venv`
  `pytest -q`) ; `ruff check` + `ruff format --check` sur les fichiers
  serveur modifiés. Le bat n'est PAS exécuté en test (pas de Windows).

## §C — Badge de délai en gras (widget + volet)

Faites vérifiés dans le code (2026-11-22) :

- `AppState.dueSuffix(item)` (`app/lib/state/app_state.dart:305`) : null si
  `compact_due` off ; retourne `S.t("overdueSuffix").trim()` = `•  en
  retard` (l10n `s.dart:36` = `"  •  en retard"`, l'EN `:231` = `"  •
  overdue"`) ou `dueLabel(d, withTime: false)` (ex. « demain », sans puce).
- **Widget Android** : `widget_service.dart:54-61` concatène le badge dans
  la ligne : `"${label}  •  $badge"` → pour un retard, la puce est
  **doublée** (`label  •  •  en retard`) ; la ligne est un **seul**
  TextView `item_row_label` (`widget_item_row.xml`, `maxLines=1`,
  `ellipsize=end`) → le badge fin de ligne est **tronqué** dès que le label
  est long = « l'icône n'apparait pas ». L'adapter
  (`WidgetItemAdapter.kt:50-92`) lit la clé `list_<i>_item_<j>` et pose le
  texte.
- **Volet Windows** : protocole tabulé `I\t<id>\t<done>\t<label>\t<due>`
  (`flyout_bridge.dart:79-81`, `_clean` ne fait que remplacer tabs/newlines,
  pas de trim) ; rendu C++ `flyout_window.cpp:423-424` :
  `item.label + "  \u2022  " + item.due` sur un `ListView` **standard**
  (owner-draw seulement pour les boutons, `WM_DRAWITEM` ligne 661) → puce
  doublée pour les retards, et **impossible** de griser/barrer une partie
  de l'item sans owner-draw. `font_bold_` existe déjà
  (`flyout_window.cpp:175`, `FW_SEMIBOLD`).
- **App UI (inchangée)** : `home_screen.dart:745-749` rend déjà le badge en
  `Text` (11.5, outline) — pas d'icône ; hors périmètre.

### §C.1 — Données widget (Dart)

- `widget_service.dart` : plus de concaténation du badge dans le label.
  Deux clés par item : `list_<li>_item_<i>` = `✓/☐ label` (sans badge,
  comportement S2 inchangé) et `list_<li>_item_<i>_due` = `dueSuffix(item)`
  brut (« •  en retard » / « demain » / `""` si absent).
- R-C1 (test Dart existant du widget service, à étendre) : après
  `writeWidgetData`, la clé `_due` contient le suffix exact (retard : puce
  incluse, une seule fois ; futur : sans puce) ; la clé label ne contient
  **plus** de `•` ni de « en retard » ; item sans due → clé `_due` = `""`.

### §C.2 — Rendu widget (Kotlin + layout)

- `widget_item_row.xml` : le TextView unique devient un `LinearLayout`
  horizontal : `item_row_label` (width 0dp, weight 1, ellipsize end,
  maxLines 1, comme aujourd'hui) + `item_row_due` (wrap_content,
  `textStyle="bold"`, 12sp, même couleur posée par l'adapter,
  `visibility=gone` par défaut, `maxLines=1`, `ellipsize=end`, margin
  start 6dp). Le label reprend la place du badge → le badge n'est plus
  tronqué (c'est la correction du « n'apparait pas »).
- `WidgetItemAdapter.kt` : lit `list_<li>_item_<i>_due` ; si non vide →
  `setTextViewText(R.id.item_row_due, due)` + `setViewVisibility(
  R.id.item_row_due, VISIBLE)` (couleur due = couleur label, posée comme
  l'aujourd'hui via l'action réflexion `setTextColor` API<31) ; sinon
  GONE. Le label est rendu comme aujourd'hui (prefix ✓/☐).
- R-C2 : preuve = `flutter build apk --debug` vert + retest device
  utilisateur (pas d'infra unitaire Kotlin) : sur une ligne à label long, le
  badge gras est visible en fin de ligne, pas de puce doublée, item sans due
  → pas de texte parasite.

### §C.3 — Rendu volet (C++)

- Le `ListView` des items passe en `LVS_OWNERDRAWFIXED` ; le handler
  `WM_DRAWITEM` (à côté de celui des boutons) dessine par index :
  1. case + label en `font_` (position x après la case, comme aujourd'hui) ;
  2. si `due` non vide : « •  » + due en `font_bold_`, dans le même run,
     tronqué si le run dépasse la largeur (le label, lui, reste
     ellipsis-friendly comme avant — le texte label est dessiné avec
     `DT_SINGLELINE|DT_PATH_ELLIPSIS`).
- La concaténation `label + "  \u2022  " + due` (lignes 423-424) est
  **supprimée** (plus de puce ajoutée par le C++ : la puce du retard vient
  de l10n, celle du futur est ajoutée une seule fois par le runner owner-draw
  « •  » avant le due). Résultat visuel : `label  •  en retard` (gras sur
  `en retard`… plus précisément : le « •  » en gras avec le due, label
  normal) — **correction de la puce doublée** + gras demandé.
- Pas de changement de protocole Dart (`I\t…` identique) → les tests
  `app/test/flyout_items_test.dart` restent verts sans modification.
- R-C3 : preuve = lecture source (owner-draw + `font_bold_` + suppression de
  la concaténation) + build Windows de la prochaine release (le workflow
  compile le runner : un régress C++ est visible) + test device utilisateur
  (pas de toolchain Windows en local).

## Tests (plan TDD du run)

Ordre rouge → vert, par lot :

1. §B.1 : test serveur `/version` (200 + valeur + 200 unknown + pas de
   percée auth) → implémentation + `server/VERSION`.
2. §B.2/§B.3 : tests Dart `UpdateInfo` (parsing GitHub, semver, serveur
   requis, échecs) → `update_service.dart`.
3. §B.4 : widget test dialog réglages → ligne + dialog.
4. §B.5 : tests Dart du bat + de la décomposition → service Windows.
5. §B.6 : manifest + provider + method channel (compilation).
6. §A : document `docs/ops/server-migration.md` + test de lecture
   (marqueurs).
7. §C.1 : extension du test widget service (clés `_due`).
8. §C.2/§C.3 : layout XML + Kotlin + C++ (preuve par build + source).
9. Fin : suite complète Dart (`flutter test`), `flutter analyze`,
   `flutter build apk --debug`, suite serveur `pytest -q`, `ruff check` +
   `ruff format --check`.

Pas de test tautologique : chaque test vérifie une règle R-* (comportement),
pas la réécriture du code.

## Hors périmètre (noté, non tranché)

- UI app (Dart) du badge : déjà en texte, pas d'icône — inchangé.
- Web : pas de self-update (lien vers le release dans le dialog §B.4).
- iOS : pas d'artefact de release iOS — inchangé.
- MSIX / Squirrel / Play Store : rejetés (surface inutile pour une app
  perso) — le zip+bat et l'APK+intent couvrent les deux cibles de release.
- Notifications push de mise à jour : pas demandées.
- Bump automatique du `server/VERSION` par le workflow : pas fait (le
  workflow build sur le tag ; le VERSION est bumpé dans le commit de la
  release, avec le tag) — à noter dans le runbook §A/procédure release.

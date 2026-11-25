# Lot DB backend flag + import/export — tapitask (2026-11-25)

Suite de `421165a` (lot prod 4 : 228 serveur + 3 skipped / 132 flutter,
ruff 93→0, smoke PG 19 réel, CI harness verte).
Ce lot est une **feature** (pas un audit) : TDD, surface minimale,
pas de refactors hors périmètre.

## Contexte / décisions
- **D-1** : le flag `DB_BACKEND=postgres|sqlite` (défaut `postgres`,
  comportement actuel inchangé) choisit la base de déploiement.
  Compose v2 ne branche pas un service sur une variable d'env, donc :
  le service `db` passe sous `profiles: ["pg"]` dans
  `docker-compose.yml`, et un wrapper minimal `scripts/compose-up.sh`
  (sh POSIX) lit `DB_BACKEND` depuis `.env` et lance
  `docker compose -f docker-compose.yml up -d` (postgres) ou
  `docker compose -f docker-compose.sqlite.yml up -d` (sqlite).
  Documentation dans `DEPLOIEMENT-UBUNTU.md` + `.env.example`.
- **D-2** : `docker-compose.sqlite.yml` : `api` (+ `web`/`caddy`
  profiles identiques au fichier PG), **sans** service `db`, sans
  `depends_on`, `DATABASE_URL=sqlite+aiosqlite:////data/checklists.db`,
  volume nommé `data:/data` (le fichier de base survive au rebuild),
  même exposition loopback / mêmes env SMTP/rate-limit que le
  `api` PG. Zéro `DB_PASSWORD` requis en mode sqlite.
- **D-3** : le serveur durcit le chemin SQLite **fichier** (non
  `:memory:`) dans `server/app/db.py` : `PRAGMA journal_mode=WAL` +
  `busy_timeout` (10 s) au connect (engine event) ; le `StaticPool`
  actuel est conservé UNIQUEMENT pour `:memory:` (tests) — un pool
  statique sur fichier serait une régression en concurrence.
- **D-4** : le JSON est le format **natif** (1:1 avec les modèles —
  l'agent énumère les champs réels de `Checklist`/`Item`, y compris
  récurrence) ; l'import JSON **crée toujours de nouvelles listes**
  (jamais de merge ni d'écrasement — aucune donnée existante n'est
  touchée ; l'utilisateur supprime l'ancienne liste s'il veut).
  Les exports excluent membres/webhooks/ChangeLog/tokens (documenter —
  une migration de listes entre comptes reste possible, les
  invitations non).
- **D-5** : Obsidian markdown = `- [ ]` / `- [x]` + titre ; l'échéance
  sort via notre propre convention de fin de ligne
  ` (échéance YYYY-MM-DD)` — importable par notre importeur, lisible
  dans Obsidian ; **aucune** tentative de parser les syntaxes
  natives Obsidian/other plugins (hors périmètre, documenter).
  Titre de la liste = premier H1 sinon nom de fichier.
- **D-6** : CSV = **export uniquement** (demandé), séparateur `;`
  (convention Excel FR), header, une ligne par item,
  `liste;titre;fait;echeance;ordre`, `fait` 0/1, dates ISO 8601.
- **D-7** : UI — un menu « Exporter » / « Importer » dans la
  list_screen (export JSON/Markdown/CSV de la liste) + l'export
  global (`scope=all`) et l'import dans les réglages (ou l'écran home
  si c'est plus naturel — l'agent choisit le site minimal et
  documente). Le file picker existant du lot précédent (import
  TOTP/autres) est réutilisé si présent, sinon `file_picker`
  minimal.

## F1 — Flag DB backend (D-1, D-2, D-3)
- `docker-compose.yml` : service `db` → `profiles: ["pg"]` ; le reste
  du fichier inchangé (le mode PG reste le défaut : le wrapper
  default = postgres).
- `docker-compose.sqlite.yml` : comme D-2.
- `scripts/compose-up.sh` : lit `.env` (`DB_BACKEND`, défaut
  postgres), lance le bon compose ; erreurs explicites si .env absent
  ou valeur inconnue.
- `.env.example` : section « Backend base de données » (`DB_BACKEND`
  + commentaires) ; `DEPLOIEMENT-UBUNTU.md` : recette sqlite +
  **recette de migration PG→SQLite** : export JSON global
  (F2) → déploiement sqlite → import.
- `server/app/db.py` : WAL + busy_timeout sur SQLite fichier (D-3).
- **Tests** : unitaires — engine SQLite fichier temp (tmp_path) →
  `PRAGMA journal_mode` retourne `wal`, busy_timeout > 0 ; `:memory:`
  conserve StaticPool (pas de WAL, inchangé) ; le mode PG ne change
  rien (pas de pragma sqlite). Smoke manuel documenté (compose
  sqlite up → register + sync OK) — exécuté une fois par l'agent
  (docker dispo, image locale `postgres:19-alpine` déjà pullée —
  pour le smoke sqlite, docker-compose.yml suffit : aucun pull
  requis, images locales nginx/caddy si le profil est testé).

## F2 — Export/import JSON (D-4)
- Format v1 : `{"tapitask": 1, "exported_at": "<iso>", "lists":
  [{id, title, color, folder, items: [tous les champs Item réels —
  énumérés au code] }]}` — IDs conservés (l'import les régénère —
  décision : l'import attribue de nouveaux UUID, car les IDs servent
  au sync/LWW ; documenter).
- Routes (auth + droits d'accès à la liste) :
  - `GET /lists/{id}/export.json`
  - `GET /export.json?scope=all` (listes possédées + membres)
  - `POST /import` (body JSON) → crée les listes, 201, répond avec
    les listes créées ; corps non-conforme → 400 (message uniforme).
- **Tests** : export d'une liste avec items (champs complets, y
  compris récurrence) ; export scope=all (2 comptes, partage —
  l'exporteur ne voit que ses accès) ; import roundtrip (export →
  import → mêmes titres/champs, nouveaux UUIDs) ; import corps
  invalide → 400 ; import sans token / liste d'un autre → 401/403.

## F3 — Obsidian markdown (D-5)
- `GET /lists/{id}/export.md` : `# <titre>` puis une ligne
  `- [ ]` / `- [x]` par item + ` (échéance YYYY-MM-DD)` si échéance.
- `POST /import` accepte un body markdown (détection : premier
  caractère `- [`) → même logique de création que D-4.
- **Tests** : export (done/non-done/échéance) ; import de md
  (H1 + checkboxes + convention échéance ; sans H1 → nom de
  fichier ; `- [ ]` vide ignoré ; texte non-liste ignoré sans
  casser les items valides).

## F4 — CSV export (D-6)
- `GET /lists/{id}/export.csv` + `GET /export.csv?scope=all` :
  header `liste;titre;fait;echeance;ordre`, lignes échappées
  (virgules/points-virgules dans les titres), `Content-Disposition`
  avec un nom de fichier propre.
- **Tests** : export d'une liste (header + lignes + échappement),
  scope=all, liste vide (header seul).

## UI (D-7)
- Menu « Exporter » (JSON / Markdown / CSV) dans la list_screen +
  « Importer » (JSON ou Markdown) ; export/import global dans
  réglages/home (site choisi et documenté par l'agent).
- **Tests** : widget tests — présence et câblage des items du menu
  (spy sur l'appel API), résultat d'import réussi/échoué (snackbar /
  état) ; le file picker est mocké (pas d'I/O réel dans les tests).

## Annexe — périmètre doc (ajouté par l'utilisateur, 2026-11-25, même lot/commit)
Après l'implémentation F1–F4 + UI, revue COMPLÈTE de la doc produit :
`README.md`, `DEPLOIEMENT-UBUNTU.md`, `SECURITY.md`, `app/README.md`,
`server/README.md`, `docs/ops/server-migration.md`, `.env.example`
(specs/ exclues — historiques, ne pas toucher).
1. Intégrer les nouveautés du lot : `DB_BACKEND` (postgres|sqlite, défaut
   postgres), `docker-compose.sqlite.yml`, `scripts/compose-up.sh`,
   export/import JSON + Obsidian markdown + export CSV (routes, formats,
   limites), WAL + busy_timeout SQLite fichier.
2. Revue anti-reliquats OBSOLÈTES : chaque affirmation vérifiée contre le
   code réel après les lots prod 3 / prod 4 et ce lot (fichiers/scripts
   supprimés ou renommés, comptes de tests ou versions, ports/profiles/
   variables d'env cohérents avec docker-compose.yml + .env.example,
   features absentes, sections contradictoires). Corriger, pas ajouter à
   côté ; supprimer ce qui est mort. Reliquat ambigu → documenté dans le
   rapport, pas supprimé.
3. Style : pas de marketing, pas de boilerplate, court et exact, français,
   chaque correction vérifiée contre le code (pas de réécriture à l'aveugle).

## Livrables
- **pytest** : 228 baseline + nouveaux, 2× stable (module P1 prod 4
  skip sans DSN) ; `flutter analyze --no-pub` no issues ;
  `flutter test` 132 baseline + nouveaux, 2× stable ;
  `flutter build apk --debug` vert.
- `ruff check . && ruff format --check .` verts à la racine
  (le gate pre-push est actif — `extend-exclude specs/` déjà en place
  ; le spec est commité avec le lot, les rapports non).
- Smoke compose sqlite exécuté une fois (F1) ; smoke PG
  (`scripts/pg-smoke.sh`) relancé → vert (le lot ne doit pas casser
  le mode PG — c'est le mode par défaut).
- `git diff --cached --stat` vérifié avant chaque add ;
  `REVIEWER=hermes python3 scripts/review.py record` ; commit
  conventionnel `feat:` ; push origin main ; CI (`harness`) verte
  sur le nouveau sha.
- Déviations par rapport à la spec : toutes documentées.

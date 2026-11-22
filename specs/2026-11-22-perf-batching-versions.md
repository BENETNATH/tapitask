# Spec : perf — batching des commits (sync + bulk) et montée pg19 / python 3.15

Date : 2026-11-22 — Statut : brouillon

## Contexte

Profilage réel (staging, données seedées + charge synthétique 19k lignes) : à
l'échelle personnelle, tout le CPU pure-Python est < 50 ms — aucun port Rust
justifié. Les seuls hotspots sont la **cadence de commits** (sync : 18 ms/
événement ; bulk 500 items : 2,6 s dont 97 % = commits individuels) et les
versions (postgres 16 / python 3.12). Cette spec batte les commits et monte les
versions, sans toucher au reste.

## Périmètre

- §1 — `record_change` : paramètre optionnel `commit` (défaut inchangé).
- §2 — bulk `add_items` : un seul commit pour les lignes de changelog.
- §3 — sync : un savepoint par événement, un commit de fin de batch.
- §4 — versions : docker-compose → postgres:19-alpine ; server/Dockerfile →
  python:3.15-slim.
- Hors périmètre (l'agent ne tranche pas) : client Flutter/Dart, endpoints REST
  hors bulk (leur commit par opération est un comportement voulu), webhooks,
  `orjson`, pagination, déploiement staging VM (l'user pilote), venv local de
  test (reste python 3.12 — les tests tournent dedans ; l'image fait foi pour
  3.15).

## §1 record_change : paramètre commit optionnel

`server/app/events.py:89-108` — `record_change(...)` termine par
`await session.commit()`. Ajouter un paramètre `commit: bool = True` : si
`commit=False`, la ligne `ChangeLog` est simplement `session.add`ée (aucun
commit). Tous les call-sites existants (`server/app/routers/lists.py:102,236,
266,283,303,335,393,462`, `server/app/mcp_http.py:305`) gardent le comportement
actuel (commit par appel) — seul l'appel passe `commit=False`.

## §2 bulk add_items : un commit pour le changelog

`server/app/routers/lists.py:179-186` — après le commit des items, la boucle
appelle `record_change` par item (1 commit par ligne ; 500 items = 500 commits,
mesuré 97 % du coût du bulk). Comportement voulu : les `ChangeLog` du bulk sont
insérées **sans commit intermédiaire** et le commit final déjà présent
(`lists.py:186`, après la boucle) les couvre. La réponse (liste d'`ItemOut`) et
le `notify_list` final sont inchangés.

## §3 sync : savepoint par événement, commit de fin

`server/app/routers/sync.py:50-58` (boucle d'application) + les fonctions
`_apply_event` (151), `_apply_list_create` (208), `_apply_item_upsert` (252),
`_apply_item_delete` (294) et la branche list.rename (226-230) : chaque
fonction fait `await session.commit()` en cours d'événement et appelle
`record_change` (qui commite). Comportement voulu, en conservant strictement les
sémantiques actuelles :

1. **Isolement par événement** : un événement refusé (HTTPException 403/404
   `accessible_list`) est enregistré dans `rejected` et ses écritures partielles
   sont annulées — **sans** annuler les événements déjà appliqués dans le batch
   (savepoint SQL par événement : `async with session.begin_nested():`).
2. **Un seul commit** à la fin de la boucle, après tous les événements
   applicables. Les `session.commit()` internes aux fonctions `_apply_*` et
   list.rename sont retirés ; `record_change` y est appelé avec `commit=False`.
3. **Erreurs infrastructure** : une exception non-HTTPException (DB morte,
   timeout, deadlock…) propage toujours vers la 500 — le client relance tout le
   batch ; rien n'est partiellement appliqué côté client.
4. **Notifications WS différées** : `notify_list` (`events.py`) lit la
   liste/membres dans une session FRAÎCHE — avant le commit final, une
   `list.create` du batch serait invisible et sa notification serait perdue.
   Les appels `notify_list` des fonctions `_apply_*` deviennent des
   **enregistrements** `(list_id, payload)` collectés pendant la boucle,
   émis via `notify_list` **après** le commit final, dans l'ordre des
   événements. Contenu et ordre des messages inchangés (4 sites :
   list.delete 166, list.create 249, item.upsert 291, item.delete 309).
5. **LWW et guards inchangés** : le rejet par timestamp (`_apply_item_upsert`),
   la garde de re-parenting (accessible sur l'ancienne liste), le spawn
   récurrence — aucun changement de logique.
6. `accessible_list` reste appelé par événement (pas de pré-fetch : la
   vérification d'accès au moment de l'événement est le comportement voulu).

## §4 Versions

- `docker-compose.yml:3` : `postgres:16-alpine` → `postgres:19-alpine`.
- `server/Dockerfile:1` : `python:3.12-slim` → `python:3.15-slim`.
- Pas de changement de dépendance : la preuve que l'ensemble est compatible
  3.15, c'est le **build de l'image** (§ Tests). Pas de bump de pins sinon.
- Note pour l'user (hors code) : la montée Postgres 16 → 19 est une migration
  majeure — le volume staging existant passe par pg_dump/restore à la
  réinstallation (l'user pilote la VM).

## Tests

- §1 : un call-site avec `commit=False` laisse la ligne visible **après** un
  commit ultérieur sur la même session ; sans le paramètre, le commit se fait
  (un call-site REST existant vérifie que sa ChangeLog est déjà visible dans
  une session fraîche — comportement inchangé).
- §2 : bulk de N items → N lignes `ChangeLog` de kind `item.upsert` présentes
  **après** la réponse, avec `list_id`/`item_id` corrects ; la réponse contient
  N `ItemOut`.
- §3 : batch mixte `[valide, rejeté(403), valide]` → `rejected = [id_moyen]`,
  les événements 1 et 3 sont **persistés** (vérifiés en session fraîche après
  la requête) ; un batch où le 2e événement échoue n'annule pas le 1er.
  LWW : un `item.upsert` avec `updated_at` plus ancien que l'existant n'écrit
  rien (test existant conservé vert). Erreur infra : un faux rollback/exception
  non-HTTPException dans un événement → la requête 500, aucune écriture du
  batch n'est commitée, le client peut rejouer le batch. Notifications : après
  un batch `[list.create, item.upsert]`, le hub reçoit les 2 messages dans
  l'ordre, avec le bon `list_id` — y compris la notification de la liste créée
  (cas perdue en session fraîche si non différée).
- §4 : `docker build server/` vert (python:3.15-slim + pins actuels) ; smoke
  conteneur : app + `postgres:19-alpine`, `/health` 200, un round-trip
  register→login→sync via l'API (le round-trip sync prouve asyncpg sur PG19).
- TDD : tests rouges avant implémentation. Pas de test tautologique.
- En fin de run : suite complète `cd server && .venv/bin/python -m pytest -q`
  verte (sqlite in-mémoire — les savepoints y sont supportés).

## Hors périmètre (noté, non tranché)

- Pagination/cursor de la lecture d'items (levier si les listes montent à
  milliers — pas le cas aujourd'hui).
- `orjson` (JSON.dumps = 60 ms seulement sur une liste de 5000 items).
- Déploiement staging (one-liners user, après cette spec).
- Mesure perf de confirmation (sync500 < 4,5 s, bulk500 < 900 ms) : faite par
  l'assistant APRÈS le run, sur la replica locale — pas un critère de code.

# Runbook — Migration Postgres majeure (serveur tapitask)

Process réutilisable pour toute montée de version majeure de Postgres de ce
projet, documentant l'opération réellement exécutée sur la prod le
**2026-11-22 (PG16 → PG19)**. S'applique, mutatis mutandis, à n'importe
quelle stack docker compose du même type (un conteneur `postgres` avec
volume de data-dir).

**Depuis le lot 2026-11-25**, le service `db` est sous le profil `pg`
(défaut PG, mais le profil doit être activé) : toutes les commandes
`docker compose` ci-dessous portent `--profile pg` — sans, le projet est
rejeté (« service api depends on undefined service db »).

## Pourquoi dump/restore et pas un upgrade in-place

Depuis les images Docker Postgres 18+, le data-dir vit dans une **sous-
dossier par version majeure** (layout `pg_ctlcluster` :
`/var/lib/postgresql/19/main`), alors que les volumes Docker historiques
pointaient la racine. L'entrypoint refuse dès le boot un volume initialisé
par une version antérieure, avec le message :

```
database files are incompatible with server ... appears to be PostgreSQL data in /var/lib/postgresql
```

(`pg_upgrade` in-place n'est pas faisable à travers un simple mount de
volume sans les deux versions côte à côte dans le même système de
fichiers — or le conteneur n'expose qu'une seule version.) Un conteneur
PG19 pointé sur un volume PG16 tombe en **restart loop** dès le boot :
c'est le signal à reconnaître, pas un crash à « réparer » dans l'image.
→ On passe par dump/restore sur un volume vierge.

## Étapes (dans cet ordre)

### 1. Deux backups avant toute opération

Les deux backups **sortent du volume Docker** (exfiltration autorisée,
dossier dédié hors de compose, ex. `~/backups/tapitask-<date>/`) et on note
les compteurs de contrôle (étape 6) :

```bash
# a) dump SQL intégral (extracté du conteneur, nettoyé des lignes pg_ctl)
docker compose --profile pg exec -T db pg_dumpall -U checklists \
  | grep -v '^-- PostgreSQL database dump complete' > backup-pg16.sql
# (relever aussi les lignes pg_ctl du data-dir si présentes dans le dump)
# b) tar intégral du data-dir (filet en cas de bug du dump)
docker compose --profile pg exec db tar czf /tmp/pg16-data.tar.gz -C /var/lib/postgresql .
docker compose --profile pg cp db:/tmp/pg16-data.tar.gz ~/backups/tapitask-2026-11-22/
```

Compteurs de contrôle (avant TOUTE opération, dans la base encore vivante) :

```bash
docker compose --profile pg exec db psql -U checklists -d checklists -tAc \
  "SELECT 'items '||count(*) FROM items
    UNION ALL SELECT 'list_members '||count(*) FROM list_members
    UNION ALL SELECT 'lists '||count(*) FROM lists
    UNION ALL SELECT 'refresh_tokens '||count(*) FROM refresh_tokens
    UNION ALL SELECT 'users '||count(*) FROM users
    UNION ALL SELECT 'webhooks '||count(*) FROM webhooks;" | tee counts-before.txt
```

### 2. Arrêt de l'API

```bash
docker compose --profile pg stop api
```

Si le restore exige un DROP (voir étape 5), couper les connexions actives
restantes :

```sql
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = 'checklists' AND pid <> pg_backend_pid();
```

### 3. Volume neuf

Le layout 18+ exige un **mount unique à la racine** du data-dir (plus de
sous-dossier par version à prévoir dans le path de mount). Le volume ancien
n'est supprimé **qu'APRÈS** les deux backups de l'étape 1 :

```bash
docker compose --profile pg down
# supprimer le volume ancien (NE JAMAIS avant étape 1 terminée + vérifiée)
docker volume rm tapitask_pgdata
# re-create : docker compose --profile pg up -d (le volume neuf est recréé au mount)
```

### 4. Bring-up + restore

```bash
docker compose --profile pg up -d db        # attendre : healthy
docker compose --profile pg cp backup-pg16.sql db:/tmp/backup.sql
docker compose --profile pg exec db psql -U checklists -d postgres -f /tmp/backup.sql
```

### 5. Piège : le schéma est créé par l'application au boot

**Pas d'alembic dans ce projet** : c'est l'API qui crée les tables au boot
(`create_all` au startup). Conséquence : si l'API a démarré AVANT le
restore, les tables/FK existent déjà → le restore (COPY) échoue en cascade
et la base est polluée (tables partiellement remplies, contraintes
insatisfaites). Il n'existe pas de « fix » partiel acceptable.

Remède complet (dans cet ordre) :

```sql
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname = 'checklists' AND pid <> pg_backend_pid();
DROP DATABASE checklists;
CREATE DATABASE checklists;
```

puis re-restore propre du dump (étape 4) — puis `docker compose --profile pg up -d api`.

### 6. Vérification par compteurs

Reprendre la requête de l'étape 1 et comparer **table par table** au
fichier `counts-before.txt` : `items`, `list_members`, `lists`,
`refresh_tokens`, `users`, `webhooks` — identique = restore OK. Tout
écart = on ne continue pas, on revient à l'étape 5 (ou on restaure le
tar de l'étape 1).

### 7. Smoke

- Racine : `curl -s -o /dev/null -w '%{http_code}' https://<host>/` →
  **302** (redirect login).
- API : `curl -s https://<host>/health` → **200** `{"status":"ok"}`.
- `curl` sans token sur une route protégée → **401** (l'auth fonctionne).
- Logs : **aucun 500** après les premiers appels.
- Un **seul** worker uvicorn visible (`/proc` du conteneur) — le hub WS
  est in-process, un 2e worker casse le temps réel sans symptôme.

## Pièges notés (vécu 2026-11-22)

- **Fenêtre de consentement** : les opérations destructives (DROP
  DATABASE, suppression du volume) demandent une confirmation — prévoir
  ~5 min d'avance, la base reste inerte pendant ce temps.
- **Restart loop PG19 sur volume PG16** : le conteneur refuse le volume
  dès le boot (message « appears to be PostgreSQL data in
  /var/lib/postgresql »). C'est le signal d'entrée du runbook, pas un
  problème d'image à déboguer.
- **Ne jamais supprimer le volume ancien avant les deux backups**
  (dump + tar) sortis du volume et vérifiés lisibles.

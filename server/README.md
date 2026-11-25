# Tapitask — API Serveur

FastAPI + SQLAlchemy async. Backend de déploiement : Postgres (asyncpg) ou SQLite
fichier (aiosqlite — flag `DB_BACKEND`, WAL + `busy_timeout` au connect).
Tests sur SQLite (aiosqlite).

## Endpoints principaux

| Méthode | Chemin | Rôle |
|---|---|---|
| POST | `/auth/register` | Créer un compte (Argon2id) |
| POST | `/auth/login` | Connexion → access + refresh |
| POST | `/auth/refresh` | Rotation du refresh token |
| GET | `/auth/me` | Profil courant |
| GET/POST/PATCH/DELETE | `/lists[...]` | Listes CRUD |
| GET/POST | `/lists/{id}/items[...]` | Items ; `bulk` accepte du texte multi-lignes |
| PATCH | `/lists/{id}/items/{id}` | Cocher / renommer (LWW sur `updated_at`) |
| GET | `/lists/{id}/export.json` · `export.md` · `export.csv` | Export de la liste : JSON 1:1 modèle (y compris soft-deleted) / Markdown Obsidian / CSV `;` (header `liste;titre;fait;echeance;ordre`) |
| GET | `/export.json?scope=all` · `/export.csv?scope=all` | Export global (listes possédées + memberships) |
| POST | `/import` | Import JSON (enveloppe tapitask) ou Markdown Obsidian (détection par le corps) → **nouvelles listes, nouveaux UUIDs** (jamais de merge) ; assignés/created_by nullifiés |
| POST | `/sync` | Delta sync (push outbox + pull `since`) |
| POST | `/lists/{id}/invites` · `/lists/invites/{id}/accept` | Partage par invitation |
| POST/GET/DELETE | `/lists/{id}/members[...]` | Partage direct par email + rôles |
| POST/GET/DELETE | `/api-keys[...]` | Clés d'API (agents) |
| POST/GET/DELETE | `/lists/{id}/hooks[...]` | Webhooks signés HMAC |
| WS | `/ws?token=...` | Temps réel (listes partagées) |
| GET/POST/PATCH/DELETE | `/admin/users[...]` | Admin : lister, créer, désactiver, promouvoir, reset MDP |
| GET | `/admin/audit` | Journal d'audit (admin, ≤1000 entrées) |

Documentation interactive : `/docs` (Swagger), spec : `/openapi.json`.

## Développement local

```bash
python -m venv .venv
.venv/bin/pip install -r requirements.txt
export JWT_SECRET=$(openssl rand -hex 32)
export DATABASE_URL=postgresql+asyncpg://checklists:checklists@localhost:5432/checklists
# ou sans Postgres : export DATABASE_URL=sqlite+aiosqlite:///./tapitask.db
uvicorn app.main:app --reload
```

## Tests

```bash
.venv/bin/python -m pytest -q    # 249 tests (3 skipped sans DSN Postgres) : auth, CRUD, bulk, partage, invitations, api keys, sync, admin, webhooks HMAC, MCP, import/export, db
```

## Modèle de données

`users`, `refresh_tokens`, `api_keys`, `lists`, `list_members` (viewer/editor/owner), `items`, `invites`, `change_log`, `webhooks`.

## Synchro (contrat)

```jsonc
POST /sync
{
  "since": "2026-01-01T00:00:00Z",   // optionnel : delta depuis ce timestamp
  "events": [                        // outbox du client
    {"kind": "item.upsert", "id": "uuid", "list_id": "uuid",
     "label": "lait", "done": false, "position": 3,
     "updated_at": "2026-01-02T10:00:00Z"}
  ]
}
→ {"server_time": "...", "changes": [...]}   // changements serveur manqués
```

Résolution de conflits : **last-write-wins sur `updated_at`** (suffisant pour des cases à cocher).

## MCP (agents)

```bash
python mcp_setup.py setup            # crée la clé (fichier 0600) et affiche la commande à déclarer dans votre client MCP
export CHECKLISTS_URL=https://checklists.example.com
export CHECKLISTS_API_KEY_FILE=~/.config/tapitask/<nom>.key
python mcp_server.py
```

`CHECKLISTS_API_KEY=chk_...` (clé dans l'environnement) reste supporté ; si les deux sont
définis, le fichier l'emporte. Sous-commandes de `mcp_setup.py` : `setup`, `rotate`, `revoke`
(`--help` pour les options non interactives : `--list`, `--access`, `--name`, `--key-file`).

Outils : `list_lists`, `get_list`, `add_items`, `check_item`.

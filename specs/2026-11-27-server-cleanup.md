# Spec 2026-11-27 — Nettoyage dette qualité serveur (audit findings, priorité 3)

**Statut** : à implémenter. **Périmètre** : `server/` uniquement. Zéro
changement app Flutter. Référence :
`specs/2026-11-27-audit-findings.md` (items qualité serveur, priorité 3).

Chaque point est indépendant — implémenter et tester un par un (TDD :
test de régression qui prouve le comportement AVANT, puis le fix, puis
vert), pas un lot monolithique.

## 1. DRY — logique « listes accessibles au principal » dupliquée 4×

Même algorithme (scope API-key → liste unique ; sinon listes possédées
+ memberships, dédupliquées, owner d'abord) réimplémenté indépendamment
dans :
- `routers/lists.py:82-166` (`my_lists`, sortie `ChecklistOut` avec rôle)
- `routers/sync.py` (`_accessible_list_ids`, sortie `set[UUID]` probablement)
- `routers/import_export.py:177-232` (`_accessible_lists`, sortie `list[Checklist]`, PAS de rôle)
- `mcp_http.py` (branche `list_lists`, sortie texte/JSON pour l'outil MCP)

**Chaque site a une sortie différente** — ne PAS unifier la sortie,
seulement factoriser le CALCUL (quelles listes + quel rôle) dans
`deps.py`, à côté de `accessible_list` (singulier, déjà là) :

```python
async def accessible_lists(
    principal: Principal, session: AsyncSession
) -> list[tuple[Checklist, str]]:
    """Toutes les listes accessibles au principal, chacune avec son rôle
    ('owner' ou le rôle ListMember). Owner d'abord si la liste scope
    API-key correspond à une liste possédée ; sinon, listes possédées
    (plus récentes d'abord) puis memberships (hors listes déjà possédées,
    cf. S5 prod4 — un owner qui a accepté sa propre invitation garde une
    ligne ListMember en plus de owner_id)."""
    if principal.list_scope is not None:
        row = (
            await session.execute(
                select(Checklist).where(
                    Checklist.id == principal.list_scope,
                    Checklist.deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if row is None:
            return []
        if row.owner_id == principal.user_id:
            return [(row, "owner")]
        member = (
            await session.execute(
                select(ListMember).where(
                    ListMember.list_id == row.id,
                    ListMember.user_id == principal.user_id,
                )
            )
        ).scalar_one_or_none()
        return [(row, member.role.value)] if member is not None else []
    owned = (
        await session.execute(
            select(Checklist)
            .where(
                Checklist.owner_id == principal.user_id,
                Checklist.deleted.is_(False),
            )
            .order_by(Checklist.updated_at.desc())
        )
    ).scalars()
    result: list[tuple[Checklist, str]] = [(c, "owner") for c in owned]
    memberships = await session.execute(
        select(ListMember, Checklist)
        .join(Checklist, Checklist.id == ListMember.list_id)
        .where(
            ListMember.user_id == principal.user_id,
            Checklist.owner_id != principal.user_id,
            Checklist.deleted.is_(False),
        )
        .order_by(Checklist.updated_at.desc())
    )
    for member, checklist in memberships.all():
        result.append((checklist, member.role.value))
    return result
```

Puis faire consommer les 4 call-sites EXISTANTS par cette fonction (en
reconstruisant leur sortie propre à partir du tuple `(Checklist, role)`)
sans changer leur comportement observable (réponse HTTP/JSON
identique). **Les tests existants de chacun des 4 endpoints sont la
preuve de non-régression — aucun nouveau test requis ici, mais les 4
suites de tests concernées doivent rester vertes.**

## 2. N+1 dans l'export global (`import_export.py`, scope=all)

`_export_lists` (actuel ~ligne 235-242) fait une requête `_items_of`
PAR LISTE dans une boucle. Ajouter un helper batché (nouveau, ne touche
PAS `_items_of` existant — utilisé ailleurs pour l'export d'UNE liste) :

```python
async def _items_of_many(
    session: AsyncSession, list_ids: list[uuid.UUID], include_deleted: bool
) -> dict[uuid.UUID, list[Item]]:
    if not list_ids:
        return {}
    query = (
        select(Item)
        .where(Item.list_id.in_(list_ids))
        .order_by(Item.list_id, Item.position, Item.created_at)
    )
    if not include_deleted:
        query = query.where(Item.deleted.is_(False))
    by_list: dict[uuid.UUID, list[Item]] = {lid: [] for lid in list_ids}
    for item in (await session.execute(query)).scalars():
        by_list[item.list_id].append(item)
    return by_list


async def _export_lists(
    session: AsyncSession, principal: Principal
) -> list[tuple[Checklist, list[Item]]]:
    lists = await _accessible_lists(session, principal)  # ou accessible_lists() du point 1
    items_by_list = await _items_of_many(
        session, [c.id for c in lists], include_deleted=False
    )
    return [(c, items_by_list.get(c.id, [])) for c in lists]
```

Test : vérifier (via un compteur de requêtes SQLAlchemy — event
`before_cursor_execute`, ou en comptant les listes retournées vs le
nombre d'appels à `_items_of_many`) qu'un export avec N≥3 listes émet 1
seule requête items, pas N. La sortie JSON/CSV/MD doit être
BYTE-IDENTIQUE à avant (mêmes tests existants `test_import_export.py`
sur le contenu de l'export, à garder verts).

## 3. Index manquant pour `/admin/audit`

`routers/admin.py` (`ORDER BY ChangeLog.server_time DESC LIMIT n`, sans
filtre `list_id`) — le seul index existant
(`models.py:236`, `ix_changelog_list_time(list_id, server_time)`) est
composite avec `list_id` en tête, inutilisable pour ce tri non filtré.
Ajouter un index dédié :

1. `models.py`, `ChangeLog.__table_args__` : ajouter
   `Index("ix_changelog_server_time", "server_time")` à côté de
   l'index composite existant (tuple, pas remplacement).
2. `main.py`, `_ensure_indexes()` (actuel ~ligne 260-268, liste de DDL
   `CREATE INDEX IF NOT EXISTS`) : ajouter la ligne
   `"CREATE INDEX IF NOT EXISTS ix_changelog_server_time ON change_log (server_time)"`
   pour les bases déjà déployées (le `__table_args__` seul ne joue que
   sur `create_all`, pas sur les DB existantes).

Test : vérifier que l'index existe après `_ensure_indexes()` (requête
`PRAGMA index_list` sqlite ou `pg_indexes` postgres selon le backend du
test, suivre le pattern des tests d'index existants s'il y en a déjà
pour `ix_items_updated_at`).

## 4. Parsing CSV incohérent — `WEBHOOK_ALLOWED_HOSTS`

`config.py:63-65` fait `.split(",")` brut au lieu du helper partagé
`_parse_csv` (utilisé par `CORS_ORIGINS`/`TRUSTED_PROXIES`, ligne 6-9) :

```python
WEBHOOK_ALLOWED_HOSTS: list[str] = _parse_csv(
    os.environ.get("WEBHOOK_ALLOWED_HOSTS", "")
)
```

Test : valeur par défaut (env absente) → `[]` (pas `['']`).

## 5. Paramètre mort `field` dans les validateurs d'import

`import_export.py` — `_parse_optional_str(value, field, max_len=None)`
et `_parse_uuid(value, field)` : le paramètre `field` n'est jamais lu
dans le corps (le message d'erreur reste l'uniforme `INVALID_IMPORT`,
intentionnel d'après le docstring de `_validate_json_lists` — « message
uniforme 400 »). Supprimer le paramètre `field` des deux signatures ET
de tous les appels (`grep -n "_parse_optional_str\|_parse_uuid"` pour
les lister tous). Pas de changement de comportement, juste suppression
d'un paramètre inutilisé.

## 6. Shadowing de variable — `_build_items`

`import_export.py:407-408` (actuel) :
```python
for raw in raw:
```
réutilise `raw` (déjà le nom de `entry["items"]` plus haut dans la même
fonction) comme variable de boucle. Fonctionne aujourd'hui, fragile à
une réorganisation future. Renommer la variable de boucle en
`raw_item` (garder `raw = entry["items"]` tel quel, juste la boucle
`for raw_item in raw:` et les usages internes de `raw.get(...)` →
`raw_item.get(...)` dans CETTE boucle uniquement).

## 7. Code mort — `InviteAcceptIn`

`schemas.py:282-284` : classe `InviteAcceptIn` jamais référencée ailleurs
(`grep -rn "InviteAcceptIn" server/` → seulement sa définition).
Supprimer la classe. Si une suite grep montre un usage (ex. test dédié
qui l'importe), NE PAS supprimer — signaler à la place dans le rapport
final.

## 8. `except Exception: pass` trop large — migrations idempotentes

`main.py:185-206` (`_ensure_columns`) : chaque `ALTER TABLE ADD COLUMN`
sqlite est dans un `except Exception: pass` — avale aussi une vraie
panne (DDL invalide, permissions, connexion coupée), pas seulement
« colonne déjà existante ». Le chemin Postgres utilise déjà `ADD COLUMN
IF NOT EXISTS` (pas besoin du try/except pour l'idempotence) — ne
restreindre QUE le chemin sqlite, qui n'a pas de `IF NOT EXISTS` :

```python
async def _ensure_columns() -> None:
    from sqlalchemy import text

    for table, column, sqlite_ddl, pg_ddl in MIGRATIONS:
        if _is_postgres():
            async with engine.begin() as conn:
                await conn.execute(
                    text(
                        f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {column} {pg_ddl}"
                    )
                )
        else:
            try:
                async with engine.begin() as conn:
                    await conn.execute(
                        text(f"ALTER TABLE {table} ADD COLUMN {column} {sqlite_ddl}")
                    )
            except Exception as e:
                if "duplicate column" not in str(e).lower():
                    raise
    # ... (bloc due_date TIMESTAMPTZ postgres inchangé, lignes 208+)
```

Test : sur sqlite, ajouter deux fois la même colonne (simulateur du
cas réel « colonne déjà existante ») → pas d'exception, idempotent ;
injecter une DDL invalide dans un test ciblé (ex. type de colonne
inconnu) → l'exception DOIT maintenant remonter (pas avalée).

## 9. Dépendances mineures obsolètes

`server/requirements.txt` : bump patch/mineur uniquement (pas de
majeure) — `fastapi==0.162.5`→`0.165.0`,
`sqlalchemy[asyncio]==2.1.8`→`2.1.9`, `pyotp==2.10.0`→`2.12.2`,
`httpx==0.28.1`→`0.29.0`, `redis==8.1.0`→`8.2.0`. Réinstaller dans le
venv (`server/.venv/bin/pip install -r requirements.txt`) puis suite
complète. Si une régression apparaît sur UNE dépendance précise, NE
PAS bumper celle-là (revenir à la version pinée), documenter dans le
rapport final, et laisser les autres bumps qui passent.

## Vérification finale (après les 9 points)

1. `server/.venv/bin/python -m pytest -q` (suite complète, pas
   seulement les fichiers touchés) — verte, 0 régression sur les 252
   tests existants (+ les nouveaux tests de cette spec).
2. `ruff check .` + `ruff format --check .` (racine) — verts.
3. `git status --short` : uniquement des fichiers sous `server/` +
   `specs/2026-11-27-server-cleanup.md`.
4. Ne rien committer.

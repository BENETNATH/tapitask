# Spec 2026-11-27 — 4 fixes serveur (audit 2026-11-27)

**Statut** : à implémenter. **Périmètre** :
`server/app/routers/import_export.py` + `server/app/mcp_http.py`
UNIQUEMENT. Zéro changement app Flutter, zéro migration DB.

Référence : `specs/2026-11-27-audit-findings.md` (SEC-F1, QUAL-SRV-1,
SEC-F2, SEC-F3) — causes déjà identifiées et vérifiées par lecture de
code + script empirique ; cette spec donne le fix exact pour chacun.

## Fix 1 (SEC-F1, Élevé) — `/import` ignore le `list_scope` d'une clé API

`server/app/routers/import_export.py`, fonction `import_data` (actuel
`~ligne 484-491`, juste après la signature et avant la lecture du
body). Même garde que `create_list` (`routers/lists.py:221-224`,
Strix vuln-0002) :

```python
async def import_data(
    request: Request,
    name: str | None = Query(default=None, max_length=200),
    principal: Principal = Depends(require_write),
    _rate_limited: Principal = Depends(rate_limit_principal),
    session: AsyncSession = Depends(get_session),
):
    if principal.list_scope is not None:
        # A scoped key is bound to its single list: no creation outside
        # it (Strix vuln-0002 — même garde que create_list).
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "API key scoped to another list"
        )
    # Corps brut : JSON (enveloppe tapitask) ou markdown Obsidian — ...
```
(le reste de la fonction ne change pas, juste l'ajout de ces 4 lignes
tout en haut du corps, avant tout traitement.)

## Fix 2 (SEC-F2, Moyen) — plafond d'import non cumulatif

`server/app/routers/import_export.py`, fonction `_validate_json_lists`
(actuel `~ligne 329-389`). Le total d'items est déjà vérifié PAR LISTE
(ligne ~352) mais jamais sur l'ENSEMBLE de la requête — `_build_items`
est appelée une liste à la fois par `import_data` (ligne ~520,
`_build_items([entry], now)`), donc son propre compteur `total` ne voit
jamais plus d'une entrée. Ajouter le cumul dans `_validate_json_lists`,
qui lui voit déjà `entries` (toutes les listes de la requête) en entier :

```python
def _validate_json_lists(data: Any) -> list[dict[str, Any]]:
    """JSON parsé → listes d'entrées valides (validité stricte, message
    uniforme 400)."""
    if not isinstance(data, dict) or not isinstance(data.get("lists"), list):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    entries = data["lists"]
    if len(entries) > MAX_IMPORTED_LISTS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    total_items = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        title = entry.get("title")
        # ... (toutes les validations existantes de title/color/folder
        # restent identiques, inchangées) ...
        items = entry.get("items", [])
        if not isinstance(items, list) or len(items) > MAX_IMPORTED_ITEMS:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        total_items += len(items)
        if total_items > MAX_IMPORTED_ITEMS:
            # Plafond sur l'ENSEMBLE de la requête, pas seulement par
            # liste (SEC-F2) : sans ça, MAX_IMPORTED_LISTS × MAX_IMPORTED_ITEMS
            # items passent en une seule transaction.
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        seen_ids: set[str] = set()
        # ... (reste de la boucle sur `items` inchangé) ...
    return entries
```
Note : la vérification rejette donc dès que le CUMUL dépasse
`MAX_IMPORTED_ITEMS` (pas `MAX_IMPORTED_LISTS × MAX_IMPORTED_ITEMS`) —
plus restrictif que l'intention du commentaire du code (« total
sur l'ensemble de la requête »), mais c'est la seule limite qui existe
déjà ailleurs dans le code (`_build_items`) : garder la MÊME constante
pour ne pas en introduire une nouvelle. Si une limite globale plus
généreuse est voulue plus tard, c'est une décision produit séparée, pas
ce fix.

## Fix 3 (QUAL-SRV-1, bug fonctionnel) — MCP `check_item` ne pose pas `completed_at`

`server/app/mcp_http.py`, branche `check_item` de `_call_tool`
(actuel `~ligne 435-447`). Même sémantique que REST
(`routers/lists.py:372-380`, `patch_item`) :

```python
            done = args.get("done", True)
            if not isinstance(done, bool):
                raise ValueError("'done' must be a boolean")
            from .events import notify_list, record_change
            from .models import utcnow
            from .routers.lists import _spawn_next

            # Same semantics as REST PATCH and sync: the next occurrence of a
            # recurring item is spawned on the not-done -> done transition,
            # and _spawn_next is idempotent per source item.
            newly_done = done and not item.done
            item.done = done
            if newly_done:
                item.completed_at = utcnow()
            elif not done:
                item.completed_at = None
            item.updated_at = utcnow()
            await session.commit()
```
(seul ajout : les 3 lignes `if newly_done: ... elif not done: ...` —
`newly_done` existe déjà, `utcnow` est déjà importé localement juste
au-dessus, rien d'autre ne change.)

## Fix 4 (SEC-F3, Faible) — fuite de message d'exception brut via MCP

`server/app/mcp_http.py`, catch-all de `_call_tool` dans le handler
JSON-RPC (actuel `~ligne 231-232`) :

```python
            except Exception as e:
                logging.getLogger("tapitask").exception(
                    "MCP tools/call failed: %s", params.get("name")
                )
                message["error"] = {"code": -32603, "message": "Internal error"}
```
Ajouter `import logging` en haut du fichier si absent (vérifier
d'abord — pattern déjà utilisé ailleurs dans le serveur, ex.
`deps.py:76`, `logging.getLogger("tapitask").exception(...)`, à
reproduire à l'identique pour la cohérence). Les autres branches
(`KeyError`, `InvalidToolParam`, `HTTPException`, `ValueError`) ne
changent pas — elles restent conçues pour être montrées au client.

## Tests à ajouter (TDD, rouge d'abord)

1. **Fix 1** : `test_import_export.py` — une clé API avec `list_scope`
   posé appelle `POST /import` avec un payload JSON valide minimal →
   403 `"API key scoped to another list"`, et AUCUNE liste n'est créée
   (vérifier via `GET /lists` avec une clé non scopée du même owner, ou
   requête directe DB dans le test).
2. **Fix 2** : `test_import_export.py` — construire un payload avec
   plusieurs entrées dont la SOMME des items dépasse
   `MAX_IMPORTED_ITEMS` mais où AUCUNE entrée individuelle ne le
   dépasse (ex. 3 entrées de `MAX_IMPORTED_ITEMS // 2 + 10` items
   chacune, total > max mais chaque liste < max) → 400
   `INVALID_IMPORT`, aucune liste créée.
3. **Fix 3** : `test_mcp_*.py` (fichier MCP existant, chercher le
   pattern de test actuel pour `check_item`) — appeler l'outil MCP
   `check_item` avec `done=true` sur un item non coché → l'item en DB a
   `completed_at` non-null après l'appel ; rappeler avec `done=false` →
   `completed_at` redevient `None`. Reproduire le script empirique de
   l'audit (sqlite mémoire) sous forme de test pytest normal.
4. **Fix 4** : `test_mcp_*.py` — appeler `tools/call` avec un paramètre
   qui déclenche une exception NON `ValueError`/`HTTPException`/
   `KeyError` côté serveur (ex. `list_id` un objet JSON au lieu d'une
   chaîne, pour déclencher l'`AttributeError` dans `_uuid()` documenté
   par l'audit) → la réponse JSON-RPC contient `"message": "Internal
   error"`, PAS le texte de l'exception Python brute.

## Vérification

1. `pytest` (suite complète serveur, pas seulement les fichiers
   touchés) — verte.
2. `ruff check .` + `ruff format --check .` (racine) — verts.
3. Aucun fichier hors `import_export.py`/`mcp_http.py` (+ fichiers de
   test associés) ne doit apparaître dans `git status`.
4. Ne rien committer — l'assistant vérifie et committe après coup.

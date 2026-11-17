# Spec — corrections audit run-3 (lot D) : sync list_scope résiduel, clamp REST, my_lists scope

Date : 2026-11-17 · Repo : tapitask · Réf source : `5459399` · Suite de référence : `cd server && .venv/bin/python -m pytest --quiet` (baseline 57 passed).

TDD : test d'abord (rouge), fix minimal (vert). Surface minimale (style ponytail) : pas de refactor, pas de feature, pas de commentaire superflu, pas de nouvelle dépendance. **Ne pas committer** (l'assistant commit après vérification).

Les 3 findings sont confirmés par l'audit run-3 (`~/security-audit-skill/tapitask/run-3/findings.json`) ; le code de fix ci-dessous est celui qui a été **exécuté et vérifié** par les vérificateurs (C7-C9 my_lists, C8-C9 sync, A1/C1 clockpoison).

## Périmètre

### 1. `tapitask.sync._accessible_list_ids.list_scope_ignored` (HIGH) — server/app/routers/sync.py L183-196 + server/app/routers/apikeys.py L18-41

État actuel (vérifié) : la branche scopée (L186-189) ne vérifie que l'existence de la
ligne `Checklist` — pas `deleted=False`, pas d'accès canonical (owner ou
`ListMember` courant). Conséquence : une clé scopée dont la membership a été
révoquée, ou dont la liste est soft-deletée, lit quand même le delta de la liste ;
sur la variante cross-owner items-only, la fuite inclut les secrets webhook du
propriétaire.

Fix (sync.py) — remplacer la branche scopée par la définition d'accès canonical
(même règle que `accessible_list`, deps.py L127-146) :
```python
async def _accessible_list_ids(principal: Principal, session: AsyncSession) -> list[UUID]:
    # A scoped key sees only its list - and only if the principal still has
    # canonical access to it (same rule as accessible_list, deps.py).
    if principal.list_scope is not None:
        row = (await session.execute(
            select(Checklist.id).where(
                Checklist.id == principal.list_scope,
                Checklist.deleted.is_(False),
                or_(
                    Checklist.owner_id == principal.user_id,
                    Checklist.id.in_(
                        select(ListMember.list_id).where(ListMember.user_id == principal.user_id)
                    ),
                ),
            ))).first()
        return [row[0]] if row is not None else []
    owned = await session.execute(select(Checklist.id).where(Checklist.owner_id == principal.user_id))
    ids = [lid for (lid,) in owned.all()]
    shared = await session.execute(
        select(ListMember.list_id).where(ListMember.user_id == principal.user_id)
    )
    ids += [lid for (lid,) in shared.all()]
    return ids
```
Import : ajouter `or_` à `from sqlalchemy import select` (L7). Les lignes
non-scopées sont inchangées.

Fix (apikeys.py) — defense in depth à la création : dans `create_api_key`,
AVANT `new_api_key()` :
```python
    if data.list_scope is not None:
        # Le scope doit pointer sur une liste que le caller accède réellement
        # (404 inconnu/supprimé/non-membre) — sinon on crée une clé qui lit
        # un delta qu'elle ne devrait pas atteindre (audit run-3).
        await accessible_list(data.list_scope, principal, session)
```
Import : ajouter `accessible_list` à `from ..deps import ...` (L10). Le
comportement de `accessible_list` (404 sans membership, 403 rôle insuffisant,
403 pour un principal déjà scopé sur une autre liste) est conservé tel quel.

Tests (test_api.py) :
- `test_sync_delta_scoped_key_revoked_membership` : B crée la liste L9 + un item
  `b-item` ; B ajoute A en editor (`POST /lists/{L9}/members` pattern existant
  test_api_key_list_scope L107 du spec B / partage direct) ; A crée une clé scopée
  `list_scope=L9` ; `POST /sync` (since=past) avec la clé → le delta contient
  `b-item` (baseline avant révocation, contrôle positif) ; B retire A
  (`DELETE /lists/{L9}/members/{user_id_A}`) ; `POST /sync` avec la même clé →
  `changes` vide (aucun item de L9).
- `test_sync_delta_scoped_key_deleted_list` : A crée L1 + item `a1-item` ; clé
  scopée `list_scope=L1` ; `DELETE /lists/{L1}` (soft delete, L241) ; `POST /sync`
  avec la clé → `changes` vide.
- `test_scoped_key_creation_requires_access` : A (n'importe quelle liste de B) →
  `POST /api-keys {"list_scope": <uuid inconnu>}` → 404 ; B crée L9, A n'y est pas
  membre → 404 ; B ajoute A en viewer → 201 ; A crée L1+L2 et une clé scopée L1,
  puis avec cette clé `POST /api-keys {"list_scope": L2}` → 403 (un principal
  scopé ne peut scopé sur une autre liste).

### 2. `tapitask.sync.client_clock_lww_cursor_poison` (LOW, résidu REST) — server/app/routers/lists.py L180-184

État actuel (vérifié) : le clamp de 7468e5b couvre tous les chemins `/sync`
(`_clamp_client_dt`, sync.py L30-33) mais PAS le PATCH item REST : L180-184
accepte `data.updated_at` tel quel s'il est supérieur à la valeur stockée, avec
une garde de parité tzinfo qui dépend du round-trip du backend de stockage
(naive sur SQLite, aware sur Postgres). Un payload futur (+30 j) est stocké tel
quel sur SQLite → empoisonne le LWW (sync.py L260) et le curseur delta des
membres (sync.py L86 → sync_service.dart L265-266).

Fix : dans `patch_item`, remplacer le bloc L180-184 par le clamp serveur
identique (tolérance 5 s) + comparaison naive explicite :
```python
    if data.updated_at is not None:
        from .sync import _clamp_client_dt, _naive  # import local : sync.py importe déjà lists (L15)
        client_ts = _clamp_client_dt(data.updated_at)
        if client_ts > _naive(item.updated_at):
            item.updated_at = client_ts
```
L'import local (dans la fonction) évite l'import circulaire module-level
(sync.py L15 `from .lists import _spawn_next`). Pas d'autre changement dans
lists.py. Les autres champs (label, done, position, notes, assignee_id) sont
inchangés.

Tests (test_api.py) :
- `test_rest_patch_clamps_future_updated_at` : A crée L + item `base` ;
  `PATCH /lists/{L}/items/{id}` avec `{"label": "poison", "updated_at":
  <now+30d naive ISO>}` → 200 ; `GET /lists/{L}/items` → l'item porte `poison`
  MAIS `updated_at` ≤ now+6 s (comparer l'ISO du corps à `datetime.now(timezone.utc)`
  ; pattern du test du spec B `test_sync_clamps_future_client_clock`) ;
  `PATCH` avec `{"label": "poison-aware", "updated_at": <now+30d aware ISO>}` →
  200, `updated_at` ≤ now+6 s (la forme aware est désormais traitée pareil,
  plus de parité de round-trip) ; `PATCH` avec `{"label": "legit"}` (sans
  updated_at) → 200, label `legit` appliqué (le onupdate remet l'horloge réelle).

### 3. `tapitask.lists.my_lists.list_scope_ignored` (LOW) — server/app/routers/lists.py L30-64

État actuel (vérifié) : `my_lists` construit le résultat uniquement sur
`Checklist.owner_id == principal.user_id` + `ListMember.user_id ==
principal.user_id`, sans aucune référence à `principal.list_scope` — une clé
scopée énumère toutes les listes non supprimées de son user (y compris
cross-owner via membership), en métadonnées list-level.

Fix : en tête de `my_lists`, après la signature, brancher le scope (même
sémantique que `accessible_list`) :
```python
    # Une clé API scopée ne voit QUE sa liste — même règle que le delta-read
    # (sync._accessible_list_ids) et accessible_list (deps.py) (audit run-3).
    if principal.list_scope is not None:
        row = (await session.execute(
            select(Checklist).where(Checklist.id == principal.list_scope,
                                    Checklist.deleted.is_(False)))).scalar_one_or_none()
        if row is None:
            return []
        if row.owner_id == principal.user_id:
            role = "owner"
        else:
            member = (await session.execute(
                select(ListMember).where(ListMember.list_id == row.id,
                                         ListMember.user_id == principal.user_id)
            )).scalar_one_or_none()
            if member is None:
                return []
            role = member.role.value
        return [ChecklistOut(id=row.id, owner_id=row.owner_id, title=row.title,
                             updated_at=row.updated_at, role=role,
                             color=row.color, folder=row.folder)]
```
Les deux requêtes existantes (owned + memberships) sont conservées telles
quelles pour les principals non-scopés.

Tests (test_api.py) :
- `test_my_lists_scoped_key_sees_only_scoped_list` : A crée L1, L2 ; B crée L9 et
  ajoute A en viewer ; clé scopée de A `list_scope=L1` → `GET /lists` →
  exactement 1 entrée, id=L1, role=`owner` ; contrôle : `GET /lists` avec le JWT
  de A → 3 entrées (L1, L2, L9) ; `GET /lists` avec le JWT de B → 1 entrée (L9).
- `test_my_lists_scoped_key_no_access` : (a) A crée L1 + clé scopée L1,
  `DELETE /lists/{L1}` → `GET /lists` avec la clé → `[]` ; (b) B crée L9, ajoute A
  en viewer, clé scopée de A `list_scope=L9`, B retire A → `GET /lists` avec la
  clé → `[]`.

## Hors périmètre
- Les 2 records `needs_validation` de run-3 (receiver exporté `ListWidgetProvider`,
  crash cold-start `Uri.parse`) : en attente de validation device (checklist
  fournie à l'utilisateur) — aucune modification Android de cette spec.
- Le client Dart (clock-offset correction, suivi du spec B) : le clamp serveur
  ferme l'invariant ; pas de changement app/ de cette spec.
- Les lots A/B (ca7a372, 7468e5b) : déjà commités — ne pas toucher `sync.py`
  sauf `_accessible_list_ids` (point 1), pas de changement des clamp existants.

## Définition de fait
- Les nouveaux tests échouent d'abord (rouge) contre le code actuel, puis la
  suite complète `cd server && .venv/bin/python -m pytest --quiet` est 100 % verte
  (57 baseline + tests du lot D).
- `git status --short` ne montre que : `server/app/routers/sync.py`,
  `server/app/routers/apikeys.py`, `server/app/routers/lists.py`,
  `server/tests/test_api.py`.
- Aucun commit, aucun push, aucune tâche réseau sortante.

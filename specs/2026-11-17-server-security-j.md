# Spec J — Corrections sécurité serveur (findings Strix task.benetnath.fr)

Date : 2026-11-17 — lot J. Source : pentest Strix (rapport `~/strix_runs/task-benetnath-fr_e049/`).

## Contexte

Le pentest a confirmé 4 vulnérabilités MEDIUM sur le serveur FastAPI :
1. `POST /auth/register` = oracle d'énumération (409 email connu / 201 inconnu) ;
2. clé API `read_only` acceptée sur les routes de mutation du compte
   (`PATCH /auth/me`, `POST /auth/totp/setup` → secret TOTP révélé, `POST /auth/totp/enable`) ;
3. clé API `list_scope` : `GET /lists` retourne TOUTES les listes du propriétaire et
   `POST /lists` crée des listes hors scope ;
4. webhook : l'URL est validée en longueur seulement → POST sortant signé vers n'importe
   quel hôte (SSRF aveugle ; le seul contrôle interne/metadata est le filtre réseau d'infra).
Plus des items de durcissement : null-byte → 500, rédemption d'invite par un membre
existant → 500 brut, double membership sur self-demotion de l'owner.

## Contrats

### J1 — Réponse uniforme de register (finding #1)

`POST /auth/register` : même statut ET même corps pour email connu et inconnu
(principe : « si ce compte existe, un email de vérification a été (re)envoyé »).
L'inscription effective (création du compte + email de vérification) se fait
uniquement si l'email n'existe pas — le client n'apprend rien de l'existence.
Vérifier que le rate limiting existant couvre bien cette route (sinon le couvrir).

### J2 — Scope `read_only` global (finding #2)

La règle « un credential read_only est refusé sur toute route de mutation » est
appliquée **centralement** dans la dépendance d'authentification qui résout le
credential (API key) : si `credential.read_only` est vrai et que la requête est une
mutation (méthode non-GET) → 403, sur TOUTES les routes (y compris `PATCH /auth/me`,
`POST /auth/totp/setup`, `POST /auth/totp/enable` et toute route future). Les gardes
per-route existantes deviennent redondantes : ne pas les supprimer si elles couvrent
des cas différents (comprendre avant de toucher), mais le garde global est la défense.

### J3 — `list_scope` filtré au niveau liste (finding #3)

Si le credential porte un `list_scope` :
- `GET /lists` (et toute collection de listes) ne retourne que les listes autorisées ;
- `POST /lists` → 403 (pas de création hors scope) ;
- les checks par-liste existants sur items/members restent inchangés.

### J4 — Allowlist URL webhook au niveau application (finding #4)

Fonction de validation pure, appliquée À LA CRÉATION/MAJ du webhook ET au moment de
la livraison (défense en profondeur) :
- scheme : `https` uniquement ;
- hôte : littéral IPv4/IPv6 ou nom de domaine (résolution, rejet des noms illégaux) ;
- rejet de toute adresse résolue dans : 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10,
  169.254.0.0/16 (métadonnées incluses), 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8,
  ::1, fc00::/7, fe80::/10 ;
- pas de suivi de redirect (`follow_redirects=False` — déjà le cas, le conserver et
  l'affirmer dans la validation) ; la résolution est faite une fois, puis l'IP est
  verrouillée pour la livraison (anti DNS-rebinding).

### J5 — Durcissement (items non-vulnérabilité du rapport)

- null-byte (`U+0000`) dans les champs texte utilisateur (titres, labels, notes,
  emails d'invite…) → 400 propre, pas de 500 (validateur Pydantic ou filtre global) ;
- rédemption d'une invite par un utilisateur DÉJÀ membre de la liste → 409 propre
  (message clair), pas de 500 brut ;
- contrainte unique `(list_id, user_id)` sur les memberships + upsert : la
  self-demotion de l'owner ne crée plus de doublon de rangé (migration schema +
  code d'insertion en `INSERT ... ON CONFLICT`).

### J6 — Décision produit : champ `email` des invites

Le rapport pose la question : lier le rédempteur à l'`email` de l'invite, ou garder le
modèle share-link (token haute entropie à usage unique, sans liaison d'identité) ?
**Choix retenu : share-link** (cohérent avec « invitation par code » ; un email partagé
avec un tiers reste le scénario d'usage). Le rendre explicite : une ligne dans le
README sécurité / doc de l'endpoint, pas de code.

## Hors périmètre

- `app/` (client Flutter) : rien à toucher — ce lot est serveur uniquement.
- Pas de rotation de credential (action de déploiement, faite hors lot, voir le
  rapport Strix « Immediate »).
- Les specs I et précédentes sont hors périmètre.
- Pas de commit (l'assistant committe après vérification indépendante).

## Preuve (gates, TOUS obligatoires)

1. `cd server && .venv/bin/python -m pytest -q` → suite complète verte
   (63 tests existants + les nouveaux du lot, zéro régression)
2. Les nouveaux tests passent individuellement (exécuter par fichier)
3. Vérification manuelle des 4 PoC du rapport contre le serveur local
   (SQLite dev) : register uniforme ; read_only refusé sur les 3 routes ;
   list_scope filtré ; webhook interne rejeté par l'APPLI (pas par le réseau)

## Tests TDD (à écrire AVANT les fixes, un fichier par finding)

- `test_register_uniform.py` : register email connu vs inconnu → même statut, même
  corps ; l'email inconnu crée bien le compte, le connu ne le recrée pas.
- `test_apikey_scope_global.py` : clé `read_only` → 403 sur `PATCH /auth/me`,
  `POST /auth/totp/setup`, `POST /auth/totp/enable` ET sur une route de mutation de
  test (prouve le caractère global) ; clé read+write → passe sur ces routes.
- `test_apikey_list_scope.py` : clé scopée à 1 liste sur 3 → `GET /lists` = 1 liste,
  `POST /lists` = 403, accès items de la liste scopée OK.
- `test_webhook_url_validation.py` : le validateur pur rejette (littéraux + hôte
  résolu vers) : http://, 127.0.0.1, 169.254.169.254, 10.x/192.168.x/172.16.x, ::1,
  fc00:: ; accepte un https public ; création de webhook avec URL interne → 400 ;
  le resolveur est injectable (test avec un fake resolver, pas de DNS réel, pas de
  réseau).
- `test_share_hardening.py` : null-byte dans label/titre → 400 ; rédemption invite
  par membre existant → 409 ; self-demotion × 2 → une seule rangée de membership.

Aucun test factice : chaque test doit échouer avant le fix (rouge) et passer après
(vert) — le lot est TDD strict.

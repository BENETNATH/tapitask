# Tapitask — Sécurité

## Authentification
- Mots de passe hashés avec **Argon2id** (`argon2-cffi`)
- JWT **access 15 min** + **refresh tokens rotatifs** (30 j), stockés hashés côté serveur, révocables (`/auth/logout`)
- Verrouillage après échecs répétés + rate limiting sur `/auth/login` et `/auth/register`. La clé du rate limiter n'utilise `X-Forwarded-For` que si le pair direct est un proxy de confiance (`TRUSTED_PROXIES`) ; sinon c'est l'IP du pair direct — un client ne peut donc pas rotater un en-tête forgé pour contourner la limite
- Clés API (`chk_...`) : stockées **hashées** (SHA-256), préfixe visible pour identification, révocables individuellement, scope lecture seule ou lecture+écriture

## Transport
- **HTTPS obligatoire** : Caddy (Let's Encrypt, HSTS), redirection 80→443
- En-têtes : `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`
- CORS restreint à `CORS_ORIGINS` du `.env`

## Autorisation
- Chaque requête vérifie l'accès : owner ou membre de la liste parente (`deps.accessible_list`)
- **MCP** (`/mcp/*`) : chaque tool passe par `accessible_list` (lecture = accès viewer, écriture = rôle editor + refus des clés en lecture seule) — les ids fournis par l'appelant sont toujours ré-autorisés, y compris pour `check_item` (autorise la liste réelle de l'item)
- **Sync** : un `item.upsert` / `item.delete` qui change de liste exige le rôle editor sur **les deux** listes (celle d'origine ET la cible) — impossible de déplacer un item arbitraire dans une liste que l'on contrôle
- Rôles : `viewer` (cocher), `editor` (ajouter/supprimer), `owner` (suppression de liste, invitations, membres)
- **Comptes admin** (`is_admin`) : créés via `ADMIN_EMAIL`/`ADMIN_PASSWORD` au démarrage ou promus via `PATCH /admin/users/{id}` — peuvent lister, créer, désactiver/réactiver des comptes et réinitialiser des mots de passe. Un compte désactivé (`is_active=false`) est refusé à la connexion **et** sur chaque requête (JWT comme clés API). Un admin ne peut ni se désactiver ni se retirer son rôle.
- Aucune donnée n'est renvoyée sans token valide (401 systématique sinon)

## Infrastructure
- Postgres **non exposé** : réseau Docker interne uniquement
- Secrets via `.env` (jamais commité — voir `.gitignore`), `JWT_SECRET` obligatoire (refus au démarrage sinon)
- `docker-compose.yml` refuse de démarrer sans `JWT_SECRET`/`DB_PASSWORD` renseignés

## Recommandations de déploiement
- Générer les secrets avec `openssl rand -hex 32`
- Sauvegardes chiffrées du volume `pgdata`
- Tenir les images à jour (`docker compose pull`)
- Exposer le serveur uniquement derrière Caddy ; ne jamais publier le port 8000 directement

## 2FA & email
- **TOTP** : `/auth/totp/setup` → QR (otpauth URI) → `/auth/totp/enable` ; le login exige ensuite `totp_code`
- **Vérification d'email** : activée avec `SMTP_ENABLED=1` (voir .env.example) — login bloqué (428) jusqu'à vérification
- **Rate limiting Redis** : `REDIS_URL=redis://...` → limite partagée entre workers

## Webhooks
- Signés `X-Tapitask-Signature: sha256=<hmac>` avec le secret affiché à la création ; fire-and-forget, jamais bloquants
- **Garde SSRF** : l'URL est résolue avant l'envoi ; les hosts loopback (`127.0.0.0/8`, `::1`), privés/CGNAT (`10/8`, `172.16/12`, `192.168/16`) et link-local (`169.254/16`, dont l'endpoint cloud metadata `169.254.169.254`) sont **bloqués** par défaut. `WEBHOOK_ALLOWED_HOSTS` est une liste blanche pour des webhooks privés légitimes. `follow_redirects` reste désactivé (défaut httpx)

## Limites connues (à traiter avant production)
- Rate limiter en mémoire (par process) — passer à Redis si plusieurs workers
- Pas encore de vérification d'email (optionnel pour un usage privé)
- Journal d'audit minimal (`change_log`) — pas encore d'export/retention

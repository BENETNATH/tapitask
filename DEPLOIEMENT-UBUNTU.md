# Tapitask — Déploiement Ubuntu (de A à Z)

**Tout est assisté** : les scripts posent les questions et font les étapes.

| Étape | Où | Script |
|---|---|---|
| Déployer le serveur | sur le serveur Ubuntu | `bash scripts/deploy_server.sh` |
| Builder exe + APK + web (Linux/WSL) | machine de dev | `bash scripts/setup_tapitask.sh` |
| Builder exe + APK (Windows) | machine Windows | `scripts\setup_tapitask.ps1` |

Le guide détaillé ci-dessous explique ce que font les scripts, pour le dépannage.

Il couvre : transfert du projet sur le serveur, mise en ligne de l'API (Docker + HTTPS), build des clients (Windows, Android, webapp), et le serveur MCP pour les agents.

## Ports & reverse proxy externe (par défaut)

Par défaut, **l'API est exposée sur `API_PORT` (8000)** pour ton propre reverse proxy (TLS chez toi) :

```nginx
# Exemple nginx : TLS géré par ton proxy
server {
    server_name tapitask.mondomaine.fr;
    location / { proxy_pass http://127.0.0.1:8000; proxy_set_header Host $host; }
    # webapp : proxy_pass http://127.0.0.1:8080;  (--profile web)
}
```

- `API_PORT` / `WEB_PORT` dans `.env` — tout est configurable
- TLS intégré si tu préfères : `docker compose --profile caddy up -d` (Caddy + Let's Encrypt)
- Webapp : `docker compose --profile web up -d` (nginx sert `app/build/web`)
- `CORS_ORIGINS` doit contenir l'origine HTTPS de ton proxy

## Options avancées (.env)

- `SMTP_ENABLED=1` + `SMTP_HOST/PORT/USER/PASSWORD/FROM` → vérification d'email obligatoire
- `REDIS_URL=redis://…` → rate limiting partagé (ajoute un service redis au compose si besoin)
- 2FA : dans l'app → appel `/auth/totp/setup` (QR) puis `/auth/totp/enable`

## Compte admin par défaut

Dans `.env` : `ADMIN_EMAIL` + `ADMIN_PASSWORD` → le compte est **créé automatiquement au démarrage** s'il n'existe pas (idempotent). Le script de déploiement demande ces valeurs et peut générer le mot de passe.

## 0. Prérequis serveur

- Ubuntu 22.04/24.04, accès root/sudo
- Un domaine pointant vers le serveur (ex. `tapitask.mondomaine.fr`) — requis pour le HTTPS automatique
- Ports 80/443 ouverts

## 1. Transférer le projet sur le serveur

Depuis ta machine :

```bash
# Extraire le projet (si pas déjà fait)
python3 checklists_extract.py tapitask

# Transférer
rsync -av --exclude '.venv' --exclude '__pycache__' --exclude 'build' \
  tapitask/ utilisateur@ton-serveur:/opt/tapitask/
```

(ou `scp -r tapitask utilisateur@ton-serveur:/opt/tapitask`)

## 2. Serveur : Docker + l'API

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # puis se déconnecter/revenir

cd /opt/tapitask
cp .env.example .env
openssl rand -hex 32   # → DB_PASSWORD
openssl rand -hex 32   # → JWT_SECRET
nano .env              # DOMAIN=tapitask.mondomaine.fr, les 2 secrets, CORS_ORIGINS=https://tapitask.mondomaine.fr

docker compose up -d --build
curl https://tapitask.mondomaine.fr/health   # → {"status":"ok"}
```

Caddy obtient et renouvelle le certificat Let's Encrypt automatiquement. L'API est documentée sur `https://taputask.mondomaine.fr/docs`.

**Mises à jour** : `git pull` (ou rsync) puis `docker compose up -d --build`.

## 3. Tests du serveur (optionnel, sur le serveur ou en local)

```bash
cd /opt/tapitask/server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
JWT_SECRET=test .venv/bin/python -m pytest -q   # 9 tests
```

## 4. Build des clients (sur ta machine de dev, pas le serveur)

Prérequis : Flutter SDK ≥ 3.4 (`snap install flutter --classic` ou [flutter.dev](https://flutter.dev)). Pour Windows : Visual Studio Build Tools (C++). Pour Android : Android Studio.

```bash
cd tapitask
bash scripts/init_flutter.sh    # génère les plateformes, applique le nom Tapitask, le widget et l'icône
```

### Windows (tray + app)

```bash
cd app
flutter build windows --release
# Exécutable : app/build/windows/x64/runner/Release/tapitask.exe
# L'icône tray assets/tray_icon.ico (le « T ») est déjà déclarée.
```

Pour le démarrage automatique : `shell:startup` (Win+R) → raccourci vers `tapitask.exe`.

### Android (app + widget)

```bash
cd app
flutter build apk --release
# APK : app/build/app/outputs/flutter-release/app-release.apk
# (pour le Play Store : flutter build appbundle)
```

Installer l'APK sur le téléphone, ajouter le widget « Tapitask » sur l'écran d'accueil. Icône de l'app : `assets/app_icon.png` (à passer via `flutter_launcher_icons` si tu veux la personnaliser).

### Webapp (frontend dans Docker)

Le frontend web est le même client Flutter compilé pour le navigateur.
Le service `web` est déjà défini dans le `docker-compose.yml` (profil `web`) :
nginx sert le dossier `app/build/web`.

**1. Builder le frontend** (machine de dev avec Flutter) :

```bash
cd app
flutter build web --release
# le résultat est dans app/build/web — transférez-le sur le serveur
# (rsync : rsync -a app/build/web/ serveur:~/tapitask/app/build/web/)
```

**2. Lancer le conteneur frontend** (sur le serveur) :

```bash
docker compose --profile web up -d web
# La webapp est servie sur http://serveur:8080 (WEB_PORT dans .env)
```

**3. (Re)builder après chaque nouvelle version** : relancez `flutter build web --release`
et `docker compose --profile web restart web` (le volume nginx pointe directement
sur `app/build/web`, aucun rebuild d'image nécessaire).

**4. Option recommandée — même domaine que l'API** derrière votre reverse proxy :
pointez `/` sur `WEB_PORT` (ex. nginx : `location / { proxy_pass http://127.0.0.1:8080; }`)
et gardez `/api`, `/docs`, `/ws` sur `API_PORT`. Dans ce cas mettez
`CORS_ORIGINS=https://tapitask.mondomaine.fr` dans le `.env` et `docker compose up -d`.

(l'URL de l'API est configurable dans l'écran de login de l'app, et `CORS_ORIGINS` du `.env` doit inclure le domaine)

## 5. Premier compte + partage

1. Lancer l'app → écran « Compte & serveur » → URL `https://tapitask.mondomaine.fr` → créer un compte
2. Créer une liste, l'épingler (icône punaise) pour la voir dans le tray Windows
3. Partager : depuis l'API (`POST /lists/{id}/members` avec email + rôle) — l'UI de partage dans l'app est la prochaine étape de dev

## 6. Serveur MCP (agents)

```bash
cd /opt/tapitask/server
# créer une clé API (lecture seule pour un agent) :
curl -X POST https://tapitask.mondomaine.fr/api-keys \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"agent","read_only":false}'
# → conserver la clé chk_... affichée une seule fois

export CHECKLISTS_URL=https://tapitask.mondomaine.fr
export CHECKLISTS_API_KEY=chk_...
python3 mcp_server.py
```

## 7. Sauvegardes

```bash
# crontab -e  (quotidien 3h)
0 3 * * * docker exec tapitask-db-1 pg_dump -U checklists checklists | gzip > /var/backups/tapitask-$(date +\%F).sql.gz
```

## 8. Checklist finale

- [ ] `.env` renseigné (DOMAIN, DB_PASSWORD, JWT_SECRET, CORS_ORIGINS)
- [ ] `docker compose ps` : db + api + caddy « running/healthy »
- [ ] `https://…/health` répond, `https://…/docs` s'affiche
- [ ] App Windows : login OK, liste créée, coche instantanée, tray « T » visible
- [ ] Android : APK installé, widget affiche la liste épinglée
- [ ] MCP : `list_lists` renvoie les listes

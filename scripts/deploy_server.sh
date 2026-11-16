#!/usr/bin/env bash
# Tapitask — Déploiement assisté du serveur (à lancer SUR le serveur Ubuntu).
#   scp -r tapitask user@serveur:/opt/tapitask && ssh user@serveur
#   bash /opt/tapitask/scripts/deploy_server.sh
set -euo pipefail

ask()  { read -rp "$1 " v; echo "$v"; }
ok()   { echo -e "\e[32m✔ $1\e[0m"; }
warn() { echo -e "\e[33m⚠ $1\e[0m"; }
fail() { echo -e "\e[31m✘ $1\e[0m"; exit 1; }

cd "$(dirname "$0")/.."
ROOT=$(pwd)

echo "=========================================="
echo "   Tapitask — installation du serveur"
echo "=========================================="

# --- 1. Docker -------------------------------------------------------------
if ! command -v docker >/dev/null; then
  echo "Docker n'est pas installé. Je l'installe (sudo requis)."
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker.io docker-compose-v2 >/dev/null
  sudo systemctl enable --now docker
  ok "Docker installé"
else
  ok "Docker présent"
fi
if ! docker ps >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER"
  fail "Droits docker manquants : déconnecte-toi puis relance ce script (groupes docker)."
fi

# --- 2. Questions ----------------------------------------------------------
API_PORT=$(ask "Port de l'API [8000] :"); API_PORT=${API_PORT:-8000}
WEB_ENABLED=$(ask "Servir aussi la webapp ? [O/n] :"); WEB_ENABLED=${WEB_ENABLED:-O}
WEB_PORT=""
if [ "${WEB_ENABLED,,}" = "o" ]; then
  WEB_PORT=$(ask "Port de la webapp [8080] :"); WEB_PORT=${WEB_PORT:-8080}
fi
TLS_MODE=$(ask "TLS : (1) intégré via Caddy  (2) ton propre reverse proxy ? [2] :")
TLS_MODE=${TLS_MODE:-2}
DOMAIN=""
CORS=""
if [ "$TLS_MODE" = "1" ]; then
  DOMAIN=$(ask "Domaine du serveur (ex: tapitask.mondomaine.fr) :")
  [ -n "$DOMAIN" ] || fail "Domaine obligatoire pour le TLS Let's Encrypt."
  CORS=$(ask "Origines CORS [https://$DOMAIN] :"); CORS=${CORS:-"https://$DOMAIN"}
  DNS_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
  MY_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "$MY_IP" ]; then
    warn "Le domaine résout vers $DNS_IP mais cette machine semble être $MY_IP — vérifie le DNS."
  fi
else
  warn "Mode reverse proxy externe : l'API sera exposée sur le port $API_PORT, le TLS est ton affaire."
  CORS=$(ask "Origines CORS autorisées, séparées par des virgules (ex: https://tapitask.mondomaine.fr) :")
  [ -n "$CORS" ] || fail "CORS_ORIGINS obligatoire (l'origine de ton reverse proxy)."
fi
ADMIN_EMAIL=$(ask "Email du compte admin par défaut (vide = aucun) :")
ADMIN_PASSWORD=""
if [ -n "$ADMIN_EMAIL" ]; then
  ADMIN_PASSWORD=$(ask "Mot de passe admin (vide = généré aléatoirement) :")
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(openssl rand -base64 18)
    warn "Mot de passe admin généré : $ADMIN_PASSWORD  (conserve-le !)"
  fi
fi

# --- 3. .env ---------------------------------------------------------------
if [ -f .env ]; then
  REUSE=$(ask "Un .env existe déjà. Le réutiliser ? [O/n] :")
  REUSE=${REUSE:-O}
else
  REUSE=n
fi
if [ "${REUSE,,}" != "o" ]; then
  DB_PASSWORD=$(openssl rand -hex 32)
  JWT_SECRET=$(openssl rand -hex 32)
  {
    echo "DB_PASSWORD=$DB_PASSWORD"
    echo "JWT_SECRET=$JWT_SECRET"
    echo "API_PORT=$API_PORT"
    [ -n "$WEB_PORT" ] && echo "WEB_PORT=$WEB_PORT"
    [ -n "$DOMAIN" ] && echo "DOMAIN=$DOMAIN"
    echo "CORS_ORIGINS=$CORS"
    echo "ADMIN_EMAIL=$ADMIN_EMAIL"
    echo "ADMIN_PASSWORD=$ADMIN_PASSWORD"
  } > .env
  chmod 600 .env
  ok ".env généré (secrets aléatoires, droits 600)"
fi

# --- 4. Lancement ----------------------------------------------------------
PROFILE_ARGS=()
if [ "$TLS_MODE" = "1" ]; then PROFILE_ARGS+=(--profile caddy); fi
if [ "${WEB_ENABLED,,}" = "o" ]; then PROFILE_ARGS+=(--profile web); fi

echo "==> Build + démarrage des conteneurs (db, api${PROFILE_ARGS[*]:+ profiles actifs})..."
docker compose up -d --build "${PROFILE_ARGS[@]}"

echo "==> Attente de la base de données..."
for i in $(seq 1 30); do
  if docker compose exec -T db pg_isready -U checklists >/dev/null 2>&1; then
    ok "Postgres prêt"; break
  fi
  sleep 2
done

echo "==> Attente de l'API (port $API_PORT)..."
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:$API_PORT/health" >/dev/null 2>&1; then
    ok "API en ligne"; break
  fi
  sleep 2
done

[ -n "$ADMIN_EMAIL" ] && ok "Compte admin : $ADMIN_EMAIL (créé au démarrage si absent)"

echo ""
echo "=========================================="
ok "Serveur Tapitask déployé"
echo "=========================================="
echo " API        : http://localhost:$API_PORT  (docs: /docs, spec: /openapi.json)"
[ -n "$WEB_PORT" ] && echo " Webapp     : http://localhost:$WEB_PORT"
[ "$TLS_MODE" = "1" ] && echo " HTTPS      : https://$DOMAIN"
[ "$TLS_MODE" != "1" ] && echo " Reverse proxy : pointe ton TLS vers localhost:$API_PORT (et localhost:$WEB_PORT pour la webapp)"
echo " Conteneurs : docker compose ps"
echo " Logs       : docker compose logs -f api"
if [ ! -f /etc/cron.d/tapitask-backup ]; then
  echo "0 3 * * * root cd $ROOT && docker compose exec -T db pg_dump -U checklists checklists | gzip > /var/backups/tapitask-\$(date +\\%F).sql.gz" | sudo tee /etc/cron.d/tapitask-backup >/dev/null
  sudo mkdir -p /var/backups
  ok "Sauvegarde quotidienne programmée (03:00, /var/backups)"
fi
echo ""
echo "Prochaine étape : installe l'app et connecte-toi (URL du serveur : http://TON_SERVEUR:$API_PORT ou via ton proxy TLS)."

#!/bin/sh
# Tapitask — wrapper de lancement compose (spec 2026-11-25, D-1).
# Lit DB_BACKEND depuis .env (défaut : postgres) et lance le bon compose :
#   DB_BACKEND=postgres → docker compose -f docker-compose.yml --profile pg up -d
#   DB_BACKEND=sqlite   → docker compose -f docker-compose.sqlite.yml up -d
# (sh POSIX — pas de bashism.)
# Arguments transmis à docker compose : --profile X doit précéder la
# sous-commande (flag global compose), les autres (ex. --build) suivent
# « up -d » — le wrapper trie donc les deux positions.
set -eu

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    echo "ERREUR : .env introuvable. Crée-le d'après .env.example" >&2
    echo "        (au minimum JWT_SECRET, et DB_PASSWORD en mode postgres)." >&2
    exit 1
fi

DB_BACKEND=$(sed -n 's/^DB_BACKEND=//p' .env | tail -1)

EXTRA_PROFILES=""
EXTRA_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            if [ $# -lt 2 ]; then
                echo "ERREUR : --profile sans valeur." >&2
                exit 1
            fi
            EXTRA_PROFILES="$EXTRA_PROFILES --profile $2"
            shift 2
            ;;
        --profile=*)
            EXTRA_PROFILES="$EXTRA_PROFILES $1"
            shift
            ;;
        *)
            EXTRA_ARGS="$EXTRA_ARGS $1"
            shift
            ;;
    esac
done

case "${DB_BACKEND:-postgres}" in
    postgres|"")
        # --profile pg explicite : le service db est sous ce profile
        # (mode PG = défaut du projet).
        exec docker compose -f docker-compose.yml --profile pg $EXTRA_PROFILES up -d $EXTRA_ARGS
        ;;
    sqlite)
        exec docker compose -f docker-compose.sqlite.yml $EXTRA_PROFILES up -d $EXTRA_ARGS
        ;;
    *)
        echo "ERREUR : DB_BACKEND='$DB_BACKEND' inconnu." >&2
        echo "        Valeurs autorisées : postgres (défaut) | sqlite" >&2
        exit 1
        ;;
esac

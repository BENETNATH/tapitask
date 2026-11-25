FROM python:3.15-slim

WORKDIR /srv

# Conteneur non-root (audit lot T) : l'app n'écrit rien sur le disque et
# l'écoute 8000 (>1024) ne requiert aucun privilège.
RUN useradd -m api
# /data : le mode SQLite (docker-compose.sqlite.yml) y monte un volume
# nommé pour le fichier de base ; absent de l'image, docker le créerait
# root:root et l'utilisateur api n'y écrirait pas.
RUN mkdir -p /data && chown api:api /data

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Lecture seule : les fichiers copiés (root, 644/755) restent lisibles par
# l'utilisateur non-root — pas besoin de chown.
COPY app ./app
COPY VERSION .

USER api

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# IMPORTANT : rester sur UN seul worker uvicorn. Le hub WebSocket (temps
# réel des listes partagées) est en-process ; avec --workers N, les clients
# se connecteraient à un worker qui ne publie pas leurs events. Pour
# scaler : ajouter Redis pub/sub dans app/events.py d'abord.
# Les performances d'une checklist familiale n'ont pas besoin de plus d'un worker.

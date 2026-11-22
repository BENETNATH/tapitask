FROM python:3.15-slim

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# IMPORTANT : rester sur UN seul worker uvicorn. Le hub WebSocket (temps
# réel des listes partagées) est en-process ; avec --workers N, les clients
# se connecteraient à un worker qui ne publie pas leurs events. Pour
# scaler : ajouter Redis pub/sub dans app/events.py d'abord.
# Les performances d'une checklist familiale n'ont pas besoin de plus d'un worker.

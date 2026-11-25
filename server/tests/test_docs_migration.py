"""Spec §A / R-A1 — runbook docs/ops/server-migration.md.

Test = lecture du fichier : marqueurs présents + l'ordre
backup → stop → volume → restore → compteurs → smoke respecté +
le piège « schéma créé au boot » documenté avec son remède.
"""

from __future__ import annotations

from pathlib import Path

DOC = Path(__file__).resolve().parents[2] / "docs" / "ops" / "server-migration.md"


def _text() -> str:
    assert DOC.is_file(), f"le runbook doit exister : {DOC}"
    return DOC.read_text(encoding="utf-8")


def test_required_markers_present():
    t = _text()
    # Les deux commandes exactes de backup (SQL + tar du data-dir).
    assert "pg_dumpall" in t
    assert "tar " in t
    # Pourquoi pas upgrade in-place (pg_upgrade) — layout Docker 18+.
    assert "pg_upgrade" in t
    assert "appears to be PostgreSQL data in /var/lib/postgresql" in t
    # Pièce du piège : arrêt de l'API + coupure des connexions restantes.
    # Depuis le lot 2026-11-25, le service db est sous le profil pg :
    # les commandes du runbook portent --profile pg (sans, le projet
    # est rejeté « depends on undefined service db » — reproduit).
    assert "docker compose --profile pg stop api" in t
    assert "pg_terminate_backend" in t
    # Volume neuf, puis bring-up de la base.
    assert "docker compose --profile pg up -d db" in t
    # Le nom du volume est celui du compose (pgdata) — une erreur de nom
    # ferait re-attacher l'ancien volume PG16 (restart loop documenté).
    assert "docker volume rm tapitask_pgdata" in t
    # Remède du piège « schéma créé au boot ».
    assert "DROP DATABASE" in t
    # Compteurs de contrôle table par table.
    for table in (
        "items",
        "list_members",
        "lists",
        "refresh_tokens",
        "users",
        "webhooks",
    ):
        assert table in t
    # Smoke.
    assert "302" in t
    assert "401" in t
    assert "uvicorn" in t


def test_step_order():
    t = _text()
    # Ancre de chaque étape, dans l'ordre imposé par la spec.
    anchors = [
        "pg_dumpall",  # 1. backups
        "docker compose --profile pg stop api",  # 2. arrêt API
        "volume neuf",  # 3. volume neuf
        "docker compose --profile pg up -d db",  # 4. bring-up + restore
        "Vérification par compteurs",  # 6. vérification par compteurs
        "Smoke",  # 7. smoke
    ]
    pos = [t.index(a) for a in anchors]
    assert pos == sorted(pos), (
        "l'ordre backup→stop→volume→restore→compteurs→smoke doit être respecté"
    )


def test_schema_boot_pitfall_and_remedy():
    t = _text()
    # Le piège : l'application crée le schéma au boot (pas d'alembic) ;
    # si l'API a démarré avant le restore, le COPY échoue en cascade.
    assert "boot" in t.lower()
    assert "alembic" in t.lower()
    assert "COPY" in t
    # Le remède : DROP + re-restore propre, pas de fix partiel.
    assert "CREATE" in t
    i_pitfall = t.lower().index("schéma")
    i_remedy = t.index("DROP DATABASE")
    assert i_pitfall < i_remedy, "le remède doit suivre la documentation du piège"

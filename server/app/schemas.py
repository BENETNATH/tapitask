from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from .models import Role as RoleEnum


def _no_null_bytes(v: str) -> str:
    # U+0000 crashes downstream (raw 500) — reject it cleanly (Strix
    # hardening item).
    if "\x00" in v:
        raise ValueError("null bytes are not allowed")
    return v


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=10, max_length=128)

    @field_validator("password")
    @classmethod
    def strong(cls, v: str) -> str:
        if v.lower() in ("password123", "motdepasse123"):
            raise ValueError("password too common")
        return v


class LoginIn(BaseModel):
    email: EmailStr
    password: str
    totp_code: str | None = None


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshIn(BaseModel):
    refresh_token: str


class UserOut(BaseModel):
    id: UUID
    email: EmailStr
    is_admin: bool = False
    settings: dict = {}


class UserSettingsIn(BaseModel):
    settings: dict


class VerifyEmailIn(BaseModel):
    token: str


class TotpSetupOut(BaseModel):
    secret: str
    uri: str


class TotpEnableIn(BaseModel):
    code: str
    disable: bool = False


class ChecklistIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    color: str | None = Field(default=None, pattern="^#[0-9A-Fa-f]{6}$")
    folder: str | None = Field(default=None, max_length=100)

    @field_validator("title", "folder")
    @classmethod
    def _check_null(cls, v: str) -> str:
        return _no_null_bytes(v)


class ChecklistOut(BaseModel):
    id: UUID
    owner_id: UUID
    title: str
    updated_at: datetime
    role: str = "owner"
    color: str | None = None
    folder: str | None = None


class ItemIn(BaseModel):
    label: str = Field(min_length=1, max_length=2000)
    parent_id: UUID | None = None
    recurrence: str = Field(default="none", pattern="^(none|daily|weekly|monthly)$")
    due_date: datetime | None = None
    notes: str | None = None
    assignee_id: UUID | None = None

    @field_validator("label", "notes")
    @classmethod
    def _check_null(cls, v: str | None) -> str | None:
        return v if v is None else _no_null_bytes(v)


class ItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    list_id: UUID
    parent_id: UUID | None = None
    label: str
    done: bool
    position: int
    recurrence: str = "none"
    due_date: datetime | None = None
    notes: str | None = None
    assignee_id: UUID | None = None
    updated_at: datetime


class ItemPatch(BaseModel):
    label: str | None = Field(default=None, min_length=1, max_length=2000)
    done: bool | None = None
    position: int | None = None
    parent_id: UUID | None = None
    recurrence: str | None = Field(default=None, pattern="^(none|daily|weekly|monthly)$")
    due_date: datetime | None = None
    notes: str | None = None
    assignee_id: UUID | None = None
    updated_at: datetime | None = None

    @field_validator("label", "notes")
    @classmethod
    def _check_null(cls, v: str | None) -> str | None:
        return v if v is None else _no_null_bytes(v)


class ItemsBulkIn(BaseModel):
    """Multi-line text: one item per line (agent & quick-add friendly)."""

    text: str = Field(min_length=1, max_length=50000)

    @field_validator("text")
    @classmethod
    def _check_null(cls, v: str) -> str:
        return _no_null_bytes(v)


class SyncEvent(BaseModel):
    kind: str = Field(
        pattern="^(item.upsert|item.delete|list.rename|list.create|list.delete)$")
    id: UUID
    list_id: UUID
    label: str | None = None
    color: str | None = None
    folder: str | None = None
    notes: str | None = None
    assignee_id: UUID | None = None
    done: bool | None = None
    position: int | None = None
    parent_id: UUID | None = None
    recurrence: str | None = None
    due_date: datetime | None = None
    updated_at: datetime


class SyncIn(BaseModel):
    since: datetime | None = None
    events: list[SyncEvent] = Field(default_factory=list, max_length=1000)


class SyncChange(BaseModel):
    kind: str
    id: UUID
    list_id: UUID
    label: str | None = None
    color: str | None = None
    folder: str | None = None
    notes: str | None = None
    assignee_id: UUID | None = None
    done: bool | None = None
    position: int | None = None
    parent_id: UUID | None = None
    recurrence: str | None = None
    due_date: datetime | None = None
    updated_at: datetime
    deleted: bool = False


class SyncOut(BaseModel):
    server_time: datetime
    changes: list[SyncChange]
    # Ids of client events the server could not apply (unknown/deleted list,
    # insufficient role…). The client must drop them from its outbox instead
    # of retrying forever (poisoned outbox).
    rejected: list[UUID] = Field(default_factory=list)


class InviteIn(BaseModel):
    hours: int = Field(default=48, ge=1, le=168)
    email: EmailStr | None = None

    @field_validator("email")
    @classmethod
    def _check_null(cls, v: EmailStr | None) -> EmailStr | None:
        return v if v is None else _no_null_bytes(v)


class InviteOut(BaseModel):
    invite_id: UUID
    list_id: UUID


class InviteAcceptIn(BaseModel):
    invite_id: UUID


class MemberIn(BaseModel):
    email: EmailStr
    role: str = Field(default="viewer", pattern="^(viewer|editor)$")

    @field_validator("email")
    @classmethod
    def _check_null(cls, v: EmailStr) -> EmailStr:
        return _no_null_bytes(v)


class MemberRoleIn(BaseModel):
    role: RoleEnum



class AdminUserCreateIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=10, max_length=128)
    is_admin: bool = False


class AdminUserPatch(BaseModel):
    is_active: bool | None = None
    is_admin: bool | None = None
    password: str | None = Field(default=None, min_length=10, max_length=128)


class SummaryOut(BaseModel):
    list_id: UUID
    title: str
    total: int
    unchecked: int
    unchecked_labels: list[str]


class WebhookIn(BaseModel):
    url: str = Field(min_length=10, max_length=2000)


class WebhookOut(BaseModel):
    id: UUID
    list_id: UUID
    url: str
    secret: str | None = None


class AdminUserOut(BaseModel):
    id: UUID
    email: EmailStr
    is_admin: bool
    is_active: bool
    is_email_verified: bool = True
    created_at: datetime


class ApiKeyIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    read_only: bool = False
    list_scope: UUID | None = None


class ApiKeyOut(BaseModel):
    id: UUID
    name: str
    key_prefix: str
    read_only: bool
    list_scope: UUID | None = None
    created_at: datetime

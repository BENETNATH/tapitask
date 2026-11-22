# Spec : changer l'email du compte

Date : 2026-11-22 — Statut : validée

## Contexte

Le user veut pouvoir changer l'email de son compte (email de connexion + email
des notifications). Aucun endpoint n'existe. Le schéma est déjà prêt
(`email_token` / `is_email_verified` — models.py:40-41, utilisés par le flux
d'inscription auth.py:113-133). Le pattern d'usage : l'email de vérification
envoie un **code à coller dans l'app** (pas de lien — `_send_verification_email`,
auth.py:32-44) ; l'endpoint `POST /auth/verify-email` prend le token en body
(auth.py:219-227).

## Périmètre

- §1 — colonne `pending_email` + migration idempotente (main.py MIGRATIONS)
- §2 — `POST /auth/change-email` : demande avec step-up mot de passe + 2FA
- §3 — `POST /auth/verify-email` : bascule l'email si changement en attente
- §4 — `POST /auth/resend-verification` : renvoie vers l'email en attente
- §5 — `GET /auth/me` : expose `pending_email` + `totp`
- §6 — app Flutter : section Compte (email courant, dialogue de changement,
  code de confirmation)
- Hors périmètre (l'agent ne tranche pas) : changement de mot de passe
  (aucun endpoint aujourd'hui, feature séparée), écran login « Vérifier mon
  email » (inchangé — flux d'inscription), écran admin, webhooks, emails
  d'invitation (partent de l'email du compte — suivent la valeur, rien à faire).

## §1 Colonne pending_email

`server/app/models.py` — le model `User` a `email_token` (l.41) et
`is_email_verified` (l.40). Ajouter :

```python
pending_email: Mapped[str | None] = mapped_column(String(320), nullable=True)
```

`server/app/main.py` — lister dans `MIGRATIONS` (l.118-133, tuples
`(table, column, sqlite DDL, postgres DDL)`), dans l'ordre des colonnes users :
`("users", "pending_email", "VARCHAR(320)", "VARCHAR(320)")`.

Sémantique : `pending_email` = l'email cible d'une demande de changement. Il
ne devient l'email du compte qu'après collage du code (§3). Cooexistence avec
le flux d'inscription : si un changement est en attente quand un token est
collé, la bascule s'applique ET le compte est marqué vérifié (l'email du
compte est le seul qui compte).

## §2 POST /auth/change-email

Nouvel endpoint dans `server/app/routers/auth.py` (router prefix `/auth`,
placer après `resend_verification`, l.231-246).

Schéma d'entrée nouveau dans `server/app/schemas.py` (à côté de
`RegisterIn` l.19-24 qui définit le pattern email) :

```python
class ChangeEmailIn(BaseModel):
    new_email: EmailStr
    password: str
    totp_code: str | None = None
```

Réponses :
- 401 « Invalid credentials » — mot de passe invalide (réponse uniforme,
  comme login auth.py:167-168)
- 401 « Code 2FA requis ou invalide » — si `user.totp_secret` est set et le
  code manquant/invalide (pattern auth.py:155-157 :
  `user.totp_secret and not (data.totp_code and verify_totp(...))`)
- 400 — `new_email` identique à l'email courant (après minuscules)
- 409 — `new_email` (minuscules) déjà porté par un autre compte
  (l'inscription fait le même check, auth.py:107-108)
- 503 « Vérification email indisponible (SMTP non configuré) » — si
  `settings.SMTP_ENABLED` est false : l'email ne doit jamais basculer sans
  vérification, et sans SMTP le code ne part pas
- 202 — demande enregistrée

Effets (tous satisfaits) :
- `user.pending_email = data.new_email.lower()`
- `user.email_token = new_email_token()`
- envoi SMTP vers le **nouvel** email via `asyncio.create_task` (best-effort,
  comme l'inscription auth.py:121-122), sujet « Tapitask — changement
  d'email », corps : « {new_email} a demandé le changement de l'adresse
  email de votre compte Tapitask. Si c'était vous, collez ce code dans
  l'application : {token}. Si ce n'était pas vous, ignorez ce message. »
  (même format de code que `_send_verification_email`, auth.py:32-44)

L'email courant n'est PAS modifié à ce stade : la connexion reste possible
avec l'ancien email et le même mot de passe.

Authentification : `principal = Depends(get_principal)` (l'endpoint est
privé — pas d'anonyme).

## §3 verify-email : appliquer la bascule

`auth.py:219-227` (endpoint existant, inchangé sinon) : après la résolution du
user par token, avant le commit :

```python
if user.pending_email is not None:
    user.email = user.pending_email
    user.pending_email = None
```

Puis le comportement existant (`is_email_verified = True`,
`email_token = None`). Un token collé termine donc soit une inscription
(rien à basculer), soit un changement d'email.

## §4 resend-verification

`auth.py:231-246` (endpoint existant). Deux changements :
- la garde `if user is None or user.is_email_verified: return None` ne doit
  PAS bloquer quand `user.pending_email is not None` (un compte vérifié avec
  une demande en attente doit pouvoir se renvoyer le code) ;
- l'envoi part vers `user.pending_email or user.email`.

Le rate-limit existant (`_login_limiter.check("resend:...")`) reste.

## §5 GET /auth/me

`auth.py:190-200` + `UserOut` dans `schemas.py` (l.271 porte
`is_email_verified`) : ajouter deux champs :
- `pending_email: str | None = None`
- `totp: bool = False` — vaut `user.totp_secret is not None`

L'app a besoin des deux pour afficher l'état d'attente et savoir si le
dialogue doit exiger le code 2FA.

## §6 App Flutter — section Compte

`app/lib/state/app_state.dart` — `reloadProfile()` (l.169-183) appelle
déjà `GET /auth/me` et ne garde que `is_admin` + `settings` : garder aussi
`email` et `pending_email` (nouveaux champs `String? email` / `String?
pendingEmail` sur `AppState`).

`app/lib/ui/settings_screen.dart` — section « Compte » (l.456, actuellement
une seule ligne « serveur ») : quand `s.api.accessToken != null` :
- nouvelle ligne « Email » au-dessus de la ligne serveur : valeur =
  `s.email ?? '…'` ; sous-titre si `s.pendingEmail != null` : « Changement en
  attente — collez le code reçu » ; tap → le dialogue §6-dialogue.
- état déconnecté : inchangé (bouton Connexion).

§6-dialogue (style des dialogues existants de l'app — compact, pas de
widget inventé ; `showDialog` + `TextField` comme dans
`app/lib/ui/list_dialogs.dart`) :
- **si pending** : un champ « Code reçu par email » → OK appelle
  `POST /auth/verify-email {"token": code}` → `reloadProfile()` ; erreur 404
  → « Code invalide ».
- **sinon** : champs « Nouvel email », « Mot de passe actuel »,
  « Code 2FA » (affiché uniquement si `me.totp == true`) → OK appelle
  `POST /auth/change-email` (JSON : new_email, password, totp_code) →
  success → `reloadProfile()` (l'état pending apparaît sur la ligne Email) ;
  erreurs affichées : 401 → « Mot de passe ou code 2FA incorrect »,
  409 → « Cet email est déjà utilisé », 503 → « Vérification email
  indisponible sur ce serveur ».

`app/lib/data/api_client.dart` — deux méthodes dans le pattern existant
(routage privé via `_` / public via `_auth`, l.39-44, 121) :
`changeEmail(newEmail, password, totpCode)` et `verifyEmail(token)`.

`app/lib/l10n/s.dart` — nouvelles clés FR + EN (pattern existant : getter +
entrée FR/EN dans la map — attention à ne pas coller dans une clé existante).

## Tests

Server (TDD — `server/tests/test_api.py`, conventions existantes : client
ASGI, users créés en direct, mailer capturé) :
- §2 : 6 erreurs (mot de passe 401 ; 2FA activé sans code 401 ; 2FA avec code
  valide 202 ; email pris 409 ; format invalide 400 ; même email 400 ;
  SMTP off 503) + happy path : `pending_email` set, `email_token` set,
  `email` inchangé, un email est parti vers la nouvelle adresse (contenu du
  corps mentionne le code).
- §3 : token avec pending → email basculé + `pending_email` None +
  `is_email_verified` True ; token sans pending → comportement
  d'inscription inchangé (email inchangé, vérifié).
- §4 : compte vérifié avec pending → un email part vers le pending (pas le
  courant) ; compte vérifié sans pending → rien n'est renvoyé.
- §5 : `/auth/me` renvoie `pending_email` (None sans demande, la valeur sinon)
  et `totp` (false sans secret, true avec).

App (`flutter test`, conventions des tests existants de l'app) :
- §6 : ligne Email affichée avec l'email du profil ; sous-titre en attente
  quand `pendingEmail` set ; dialogue non-pending : envoie le bon JSON à
  `/auth/change-email` ; dialogue pending : envoie le code à
  `/auth/verify-email` ; champ 2FA affiché seulement quand `totp=true` ;
  message d'erreur 409 affiché.

Fin de run : suite complète du server (`pytest -q`, venv `server/.venv` ou
celui du repo — vérifier) ET `flutter test` + `flutter analyze --no-pub`
dans `app/`, le tout relancé après le run.

## Hors périmètre (noté, non tranché)

- Changement de mot de passe : pas d'endpoint aujourd'hui — feature séparée
  (le step-up du §2 réutilisera le même pattern).
- Rétroactivité des sessions : les refresh tokens sont liés au `user_id`
  (pas à l'email) — les sessions actives survivent à la bascule (comportement
  voulu : c'est le user qui change d'email). Les access tokens sont courts.
- Historique du changement dans change_log : l'email du compte n'est pas un
  item de liste — non tracé.
- Purge des `email_token` orphelins : aucune (le token est effacé à la
  vérification ; un abandon de demande laisse un token dormant — sans effet,
  il ne donne accès à rien d'autre que de vérifier le changement).

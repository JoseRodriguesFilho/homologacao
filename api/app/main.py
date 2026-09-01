
from __future__ import annotations

import os
import re
import sqlite3
import threading
import time
import uuid
import hmac
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Iterator, Literal

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field

DB_PATH = os.getenv("EGOV_DB_PATH") or os.getenv("LAB_DB_PATH") or "/data/labcpf.db"
CLIENT_TOKEN = os.getenv("EGOV_API_TOKEN") or os.getenv("LAB_API_TOKEN") or ""
ADMIN_TOKEN = os.getenv("EGOV_ADMIN_TOKEN") or os.getenv("LAB_ADMIN_TOKEN") or ""
SESSION_TIMEOUT_SECONDS = int(os.getenv("EGOV_SESSION_TIMEOUT_SECONDS") or "180")
SEED_CPF = os.getenv("EGOV_SEED_CPF") or os.getenv("LAB_SEED_CPF") or ""
SEED_NAME = os.getenv("EGOV_SEED_NAME") or os.getenv("LAB_SEED_NAME") or "Aluno Teste"
SEED_ROLE = (os.getenv("EGOV_SEED_ROLE") or "aluno").strip().lower()

Role = Literal["aluno", "professor", "admin"]
Target = Literal["student", "admin"]

app = FastAPI(title="e-GOV Login API", version="11.0.0-homolog")

_stop_reaper = threading.Event()
_reaper_thread: threading.Thread | None = None


class PreviewRequest(BaseModel):
    # v11: identificacao generica. cpf continua opcional para compatibilidade com v10.
    identifier: str | None = Field(default=None, min_length=1, max_length=64)
    identifier_type: Literal["cpf", "matricula"] = "cpf"
    institution: Literal["outros", "univesp"] = "outros"
    cpf: str | None = Field(default=None, min_length=1, max_length=32)
    computer: str = Field(min_length=1, max_length=128)
    target: Target = "student"


class AuthRequest(PreviewRequest):
    pass


class HeartbeatRequest(BaseModel):
    session_id: str = Field(min_length=8, max_length=128)
    computer: str = Field(min_length=1, max_length=128)
    ip: str | None = Field(default=None, max_length=64)
    mac: str | None = Field(default=None, max_length=64)


class LogoutRequest(BaseModel):
    session_id: str = Field(min_length=8, max_length=128)
    computer: str = Field(min_length=1, max_length=128)
    reason: str = Field(default="logoff", max_length=64)


class PersonUpsert(BaseModel):
    identifier: str | None = Field(default=None, min_length=1, max_length=64)
    identifier_type: Literal["cpf", "matricula"] = "cpf"
    institution: Literal["outros", "univesp"] = "outros"
    cpf: str | None = Field(default=None, min_length=1, max_length=32)
    name: str = Field(min_length=1, max_length=200)
    role: Role = "aluno"
    active: bool = True


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def now_iso() -> str:
    return now_utc().isoformat()


def normalize_cpf(value: str) -> str:
    return re.sub(r"\D", "", value or "")


def valid_cpf(value: str) -> bool:
    cpf = normalize_cpf(value)
    if len(cpf) != 11 or cpf == cpf[0] * 11:
        return False

    for pos in (9, 10):
        total = 0
        weight = pos + 1
        for i in range(pos):
            total += int(cpf[i]) * (weight - i)
        digit = (total * 10) % 11
        if digit == 10:
            digit = 0
        if digit != int(cpf[pos]):
            return False

    return True



def normalize_matricula(value: str) -> str:
    # Homologacao: matricula Univesp numerica, sem mascara, ate 32 digitos.
    return re.sub(r"\D", "", value or "")[:32]


def normalize_identity(payload: PreviewRequest | PersonUpsert) -> tuple[str, str, str, str]:
    institution = (payload.institution or "outros").strip().lower()
    identifier_type = (payload.identifier_type or "cpf").strip().lower()
    raw = payload.identifier or payload.cpf or ""

    # Admin/professor permanecem no universo CPF; matricula e exclusiva da UNIVESP.
    if institution == "univesp" and identifier_type == "matricula":
        identifier = normalize_matricula(raw)
        if len(identifier) < 3:
            raise ValueError("matricula_invalida")
    else:
        institution = "outros"
        identifier_type = "cpf"
        identifier = normalize_cpf(raw)
        if not valid_cpf(identifier):
            raise ValueError("cpf_invalido")

    key = identifier if identifier_type == "cpf" else f"{institution}|{identifier_type}|{identifier}"
    return identifier, identifier_type, institution, key

def secure_equals(a: str, b: str) -> bool:
    return bool(a) and bool(b) and hmac.compare_digest(a.encode(), b.encode())


@contextmanager
def db(immediate: bool = False) -> Iterator[sqlite3.Connection]:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=10000")

    try:
        con.execute("BEGIN IMMEDIATE" if immediate else "BEGIN")
        yield con

        if con.in_transaction:
            con.commit()

    except Exception:
        if con.in_transaction:
            con.rollback()
        raise

    finally:
        con.close()


def table_exists(con: sqlite3.Connection, table: str) -> bool:
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    ).fetchone()
    return row is not None


def init_db() -> None:
    with db(immediate=True) as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS people (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cpf TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('aluno','professor','admin')),
                active INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL UNIQUE,
                cpf TEXT NOT NULL,
                name TEXT NOT NULL,
                role TEXT NOT NULL,
                windows_account TEXT NOT NULL,
                computer TEXT NOT NULL,
                ip TEXT,
                mac TEXT,
                status TEXT NOT NULL CHECK(status IN ('ACTIVE','LOGGED_OUT','EXPIRED','TERMINATED')),
                action TEXT NOT NULL DEFAULT 'login',
                login_at TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                logout_at TEXT,
                logout_reason TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_cpf_status
                ON sessions(cpf, status);

            CREATE INDEX IF NOT EXISTS idx_sessions_computer_status
                ON sessions(computer, status);

            CREATE INDEX IF NOT EXISTS idx_sessions_last_seen
                ON sessions(last_seen);

            CREATE TABLE IF NOT EXISTS session_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                event_type TEXT NOT NULL,
                actor_cpf TEXT,
                actor_name TEXT,
                actor_role TEXT,
                computer TEXT,
                details TEXT,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_session_events_session
                ON session_events(session_id, id DESC);
            """
        )

        # v11: acrescenta metadados da identificacao sem destruir o banco v10.
        people_columns = {row["name"] for row in con.execute("PRAGMA table_info(people)").fetchall()}
        if "identifier" not in people_columns:
            con.execute("ALTER TABLE people ADD COLUMN identifier TEXT")
        if "identifier_type" not in people_columns:
            con.execute("ALTER TABLE people ADD COLUMN identifier_type TEXT")
        if "institution" not in people_columns:
            con.execute("ALTER TABLE people ADD COLUMN institution TEXT")

        con.execute("""
            UPDATE people
            SET identifier=COALESCE(identifier, cpf),
                identifier_type=COALESCE(identifier_type, 'cpf'),
                institution=COALESCE(institution, 'outros')
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_people_identity ON people(institution, identifier_type, identifier)")

        # Migra os alunos da API v7, se a tabela antiga existir.
        if table_exists(con, "students"):
            con.execute(
                """
                INSERT OR IGNORE INTO people(cpf, name, role, active, created_at, updated_at, identifier, identifier_type, institution)
                SELECT cpf, name, 'aluno', active, created_at, updated_at, cpf, 'cpf', 'outros'
                FROM students
                """
            )

        if SEED_CPF:
            cpf = normalize_cpf(SEED_CPF)
            role = SEED_ROLE if SEED_ROLE in {"aluno", "professor", "admin"} else "aluno"

            if valid_cpf(cpf):
                con.execute(
                    """
                    INSERT INTO people(cpf, name, role, active, created_at, updated_at)
                    VALUES (?, ?, ?, 1, ?, ?)
                    ON CONFLICT(cpf) DO UPDATE SET
                        name=excluded.name,
                        role=excluded.role,
                        active=1,
                        updated_at=excluded.updated_at
                    """,
                    (cpf, SEED_NAME, role, now_iso(), now_iso()),
                )


def require_client_token(token: str | None) -> None:
    if not token or not secure_equals(token, CLIENT_TOKEN):
        raise HTTPException(status_code=401, detail="cliente nao autorizado")


def require_admin_token(token: str | None) -> None:
    if not token or not secure_equals(token, ADMIN_TOKEN):
        raise HTTPException(status_code=401, detail="administrador nao autorizado")


def expire_stale_sessions(con: sqlite3.Connection) -> int:
    cutoff = (now_utc() - timedelta(seconds=SESSION_TIMEOUT_SECONDS)).isoformat()
    stale = con.execute(
        """
        SELECT session_id, computer
        FROM sessions
        WHERE status='ACTIVE' AND last_seen < ?
        """,
        (cutoff,),
    ).fetchall()

    if not stale:
        return 0

    stamp = now_iso()

    for row in stale:
        con.execute(
            """
            UPDATE sessions
            SET status='EXPIRED',
                logout_at=?,
                logout_reason='heartbeat_timeout'
            WHERE session_id=? AND status='ACTIVE'
            """,
            (stamp, row["session_id"]),
        )

        con.execute(
            """
            INSERT INTO session_events
                (session_id, event_type, computer, details, created_at)
            VALUES (?, 'expired', ?, 'heartbeat_timeout', ?)
            """,
            (row["session_id"], row["computer"], stamp),
        )

    return len(stale)


def reaper_loop() -> None:
    while not _stop_reaper.wait(30):
        try:
            with db(immediate=True) as con:
                expire_stale_sessions(con)
        except Exception:
            # A API continua funcionando; a proxima requisicao tambem executa a expiracao.
            pass


@app.on_event("startup")
def startup() -> None:
    global _reaper_thread

    if not CLIENT_TOKEN:
        raise RuntimeError("EGOV_API_TOKEN nao configurado")
    if not ADMIN_TOKEN:
        raise RuntimeError("EGOV_ADMIN_TOKEN nao configurado")
    if SESSION_TIMEOUT_SECONDS < 60:
        raise RuntimeError("EGOV_SESSION_TIMEOUT_SECONDS deve ser >= 60")

    init_db()

    _stop_reaper.clear()
    _reaper_thread = threading.Thread(
        target=reaper_loop,
        name="egov-session-reaper",
        daemon=True,
    )
    _reaper_thread.start()


@app.on_event("shutdown")
def shutdown() -> None:
    _stop_reaper.set()


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "service": "egov-login",
        "version": "11.0.0-homolog",
        "session_timeout_seconds": SESSION_TIMEOUT_SECONDS,
    }


@app.post("/status")
def status(
    x_egov_token: str | None = Header(default=None),
    x_lab_token: str | None = Header(default=None),
) -> dict:
    require_client_token(x_egov_token or x_lab_token)
    return {
        "maintenance": False,
        "maintenance_message": "",
        "message": "",
    }


def get_person(con: sqlite3.Connection, identity_key: str) -> sqlite3.Row | None:
    return con.execute(
        """
        SELECT id, cpf, identifier, identifier_type, institution, name, role, active
        FROM people
        WHERE cpf=?
        """,
        (identity_key,),
    ).fetchone()


def target_allowed(role: str, target: str) -> bool:
    if target == "admin":
        return role == "admin"
    return role in {"aluno", "professor"}


def account_for_target(target: str) -> str:
    return "AdminEGOV" if target == "admin" else "AlunoEGOV"


@app.post("/auth/preview")
def auth_preview(
    payload: PreviewRequest,
    x_egov_token: str | None = Header(default=None),
    x_lab_token: str | None = Header(default=None),
) -> dict:
    require_client_token(x_egov_token or x_lab_token)

    try:
        identifier, identifier_type, institution, identity_key = normalize_identity(payload)
    except ValueError as exc:
        reason = str(exc)
        return {
            "recognized": False,
            "allowed": False,
            "reason": reason,
            "message": "Matricula invalida." if reason == "matricula_invalida" else "CPF invalido.",
            "name": None,
            "role": None,
        }

    with db() as con:
        person = get_person(con, identity_key)

    if person is None or not bool(person["active"]):
        return {
            "recognized": False,
            "allowed": False,
            "reason": "nao_cadastrado",
            "message": "Identificacao nao cadastrada.",
            "name": None,
            "role": None,
        }

    allowed = target_allowed(person["role"], payload.target)

    return {
        "recognized": True,
        "allowed": allowed,
        "reason": "ok" if allowed else "perfil_incorreto",
        "message": person["name"] if allowed else (
            "Use Admin e-GOV." if person["role"] == "admin"
            else "Use Aluno e-GOV."
        ),
        "name": person["name"],
        "role": person["role"],
        "identifier": person["identifier"],
        "identifier_type": person["identifier_type"],
        "institution": person["institution"],
    }


def active_sessions_for_computer(con: sqlite3.Connection, computer: str) -> list[sqlite3.Row]:
    return con.execute(
        """
        SELECT *
        FROM sessions
        WHERE computer=? AND status='ACTIVE'
        ORDER BY id DESC
        """,
        (computer,),
    ).fetchall()


def active_sessions_for_identity(con: sqlite3.Connection, identity_key: str) -> list[sqlite3.Row]:
    return con.execute(
        """
        SELECT *
        FROM sessions
        WHERE cpf=? AND status='ACTIVE'
        ORDER BY id DESC
        """,
        (identity_key,),
    ).fetchall()


def auth_denied(reason: str, message: str, **extra) -> dict:
    result = {
        "authorized": False,
        "reason": reason,
        "message": message,
        "name": None,
        "role": None,
        "session_id": None,
        "action": None,
        "windows_account": None,
    }
    result.update(extra)
    return result


def insert_event(
    con: sqlite3.Connection,
    session_id: str | None,
    event_type: str,
    computer: str,
    actor_cpf: str | None = None,
    actor_name: str | None = None,
    actor_role: str | None = None,
    details: str | None = None,
) -> None:
    con.execute(
        """
        INSERT INTO session_events(
            session_id, event_type,
            actor_cpf, actor_name, actor_role,
            computer, details, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id,
            event_type,
            actor_cpf,
            actor_name,
            actor_role,
            computer,
            details,
            now_iso(),
        ),
    )


def create_session(
    con: sqlite3.Connection,
    person: sqlite3.Row,
    computer: str,
    windows_account: str,
    action: str,
) -> dict:
    session_id = uuid.uuid4().hex
    stamp = now_iso()

    con.execute(
        """
        INSERT INTO sessions(
            session_id, cpf, name, role, windows_account,
            computer, status, action, login_at, last_seen
        )
        VALUES (?, ?, ?, ?, ?, ?, 'ACTIVE', ?, ?, ?)
        """,
        (
            session_id,
            person["cpf"],
            person["name"],
            person["role"],
            windows_account,
            computer,
            action,
            stamp,
            stamp,
        ),
    )

    insert_event(
        con,
        session_id,
        "login",
        computer,
        actor_cpf=person["cpf"],
        actor_name=person["name"],
        actor_role=person["role"],
        details=action,
    )

    return {
        "authorized": True,
        "reason": "autorizado",
        "message": person["name"],
        "name": person["name"],
        "role": person["role"],
        "session_id": session_id,
        "action": action,
        "windows_account": windows_account,
    }


@app.post("/auth/login")
@app.post("/auth/cpf")
def auth_identity(
    payload: AuthRequest,
    request: Request,
    x_egov_token: str | None = Header(default=None),
    x_lab_token: str | None = Header(default=None),
) -> dict:
    require_client_token(x_egov_token or x_lab_token)

    computer = payload.computer.strip()[:128]

    try:
        identifier, identifier_type, institution, identity_key = normalize_identity(payload)
    except ValueError as exc:
        reason = str(exc)
        return auth_denied(reason, "Matricula invalida." if reason == "matricula_invalida" else "CPF invalido.")

    with db(immediate=True) as con:
        expire_stale_sessions(con)

        person = get_person(con, identity_key)

        if person is None:
            return auth_denied("nao_cadastrado", "Identificacao nao cadastrada.")

        if not bool(person["active"]):
            return auth_denied("inativo", "Acesso desativado.")

        role = person["role"]

        if not target_allowed(role, payload.target):
            if role == "admin":
                return auth_denied("perfil_incorreto", "Use Admin e-GOV.")
            return auth_denied("perfil_incorreto", "Use Aluno e-GOV.")

        computer_sessions = active_sessions_for_computer(con, computer)

        # ADMIN:
        # - entra somente pela opcao Admin e-GOV;
        # - nao esta sujeito ao limite de uma sessao por CPF;
        # - usa uma conta Windows administrativa separada.
        if role == "admin":
            return create_session(
                con,
                person,
                computer,
                "AdminEGOV",
                "admin_login",
            )

        # PROFESSOR:
        # - nao e administrador;
        # - pode desbloquear a sessao ativa de um ALUNO nesse computador;
        # - em PC livre, pode usar a conta AlunoEGOV normalmente.
        if role == "professor":
            active_student = next(
                (s for s in computer_sessions if s["role"] == "aluno"),
                None,
            )

            if active_student is not None:
                insert_event(
                    con,
                    active_student["session_id"],
                    "professor_unlock",
                    computer,
                    actor_cpf=person["cpf"],
                    actor_name=person["name"],
                    actor_role=role,
                    details=f"desbloqueou sessao de {active_student['name']}",
                )

                return {
                    "authorized": True,
                    "reason": "professor_unlock",
                    "message": person["name"],
                    "name": person["name"],
                    "role": role,
                    "session_id": active_student["session_id"],
                    "action": "unlock",
                    "windows_account": "AlunoEGOV",
                    "session_owner_name": active_student["name"],
                    "session_owner_cpf": active_student["cpf"],
                }

            # Se ja houver outra sessao nao administrativa em AlunoEGOV,
            # o professor pode reutilizar a mesma conta tecnica.
            active_non_admin = next(
                (s for s in computer_sessions if s["windows_account"] == "AlunoEGOV"),
                None,
            )

            if active_non_admin is not None:
                insert_event(
                    con,
                    active_non_admin["session_id"],
                    "professor_access",
                    computer,
                    actor_cpf=person["cpf"],
                    actor_name=person["name"],
                    actor_role=role,
                    details="acesso autorizado na conta AlunoEGOV",
                )

                return {
                    "authorized": True,
                    "reason": "professor_access",
                    "message": person["name"],
                    "name": person["name"],
                    "role": role,
                    "session_id": active_non_admin["session_id"],
                    "action": "unlock",
                    "windows_account": "AlunoEGOV",
                }

            return create_session(
                con,
                person,
                computer,
                "AlunoEGOV",
                "professor_login",
            )

        # ALUNO:
        # 1) O mesmo CPF nao pode usar duas maquinas ao mesmo tempo.
        identity_sessions = active_sessions_for_identity(con, identity_key)

        if identity_sessions:
            same_pc = next(
                (s for s in identity_sessions if s["computer"].casefold() == computer.casefold()),
                None,
            )

            if same_pc is not None:
                insert_event(
                    con,
                    same_pc["session_id"],
                    "resume",
                    computer,
                    actor_cpf=person["cpf"],
                    actor_name=person["name"],
                    actor_role=role,
                    details="mesmo aluno retomou a propria sessao",
                )

                return {
                    "authorized": True,
                    "reason": "resume",
                    "message": person["name"],
                    "name": person["name"],
                    "role": role,
                    "session_id": same_pc["session_id"],
                    "action": "resume",
                    "windows_account": "AlunoEGOV",
                }

            other = identity_sessions[0]
            return auth_denied(
                "identifier_already_online",
                f"Identificacao ja conectada em {other['computer']}.",
                active_computer=other["computer"],
            )

        # 2) Um aluno nao assume o PC de outro aluno/professor.
        active_egov = next(
            (s for s in computer_sessions if s["windows_account"] == "AlunoEGOV"),
            None,
        )

        if active_egov is not None:
            return auth_denied(
                "computer_in_use",
                f"Computador em uso por {active_egov['name']}.",
                active_name=active_egov["name"],
            )

        # 3) Se houver Admin e-GOV ativo no PC, evita login de aluno durante manutencao.
        active_admin = next(
            (s for s in computer_sessions if s["windows_account"] == "AdminEGOV"),
            None,
        )

        if active_admin is not None:
            return auth_denied(
                "computer_in_maintenance",
                "Computador em manutencao.",
            )

        return create_session(
            con,
            person,
            computer,
            "AlunoEGOV",
            "student_login",
        )


@app.post("/sessions/heartbeat")
def session_heartbeat(
    payload: HeartbeatRequest,
    x_egov_token: str | None = Header(default=None),
    x_lab_token: str | None = Header(default=None),
) -> dict:
    require_client_token(x_egov_token or x_lab_token)

    with db(immediate=True) as con:
        expire_stale_sessions(con)

        row = con.execute(
            "SELECT * FROM sessions WHERE session_id=?",
            (payload.session_id,),
        ).fetchone()

        if row is None:
            raise HTTPException(status_code=404, detail="sessao inexistente")

        if row["status"] != "ACTIVE":
            raise HTTPException(status_code=409, detail="sessao nao esta ativa")

        if row["computer"].casefold() != payload.computer.strip().casefold():
            raise HTTPException(status_code=409, detail="computador divergente")

        con.execute(
            """
            UPDATE sessions
            SET last_seen=?,
                ip=?,
                mac=?
            WHERE session_id=? AND status='ACTIVE'
            """,
            (
                now_iso(),
                payload.ip,
                payload.mac,
                payload.session_id,
            ),
        )

    return {"ok": True, "status": "ACTIVE"}


@app.post("/sessions/logout")
def session_logout(
    payload: LogoutRequest,
    x_egov_token: str | None = Header(default=None),
    x_lab_token: str | None = Header(default=None),
) -> dict:
    require_client_token(x_egov_token or x_lab_token)

    with db(immediate=True) as con:
        row = con.execute(
            "SELECT * FROM sessions WHERE session_id=?",
            (payload.session_id,),
        ).fetchone()

        if row is None:
            return {"ok": True, "already_closed": True}

        if row["status"] != "ACTIVE":
            return {"ok": True, "already_closed": True, "status": row["status"]}

        stamp = now_iso()

        con.execute(
            """
            UPDATE sessions
            SET status='LOGGED_OUT',
                logout_at=?,
                logout_reason=?
            WHERE session_id=?
            """,
            (stamp, payload.reason, payload.session_id),
        )

        insert_event(
            con,
            payload.session_id,
            "logout",
            payload.computer,
            details=payload.reason,
        )

    return {"ok": True, "status": "LOGGED_OUT"}


@app.get("/admin/people")
def list_people(
    x_admin_token: str | None = Header(default=None),
) -> list[dict]:
    require_admin_token(x_admin_token)

    with db() as con:
        rows = con.execute(
            """
            SELECT cpf, identifier, identifier_type, institution, name, role, active, created_at, updated_at
            FROM people
            ORDER BY role, name, institution, identifier
            """
        ).fetchall()

    return [
        {
            "identifier": row["identifier"],
            "identifier_type": row["identifier_type"],
            "institution": row["institution"],
            "name": row["name"],
            "role": row["role"],
            "active": bool(row["active"]),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }
        for row in rows
    ]


@app.post("/admin/people")
def upsert_person(
    payload: PersonUpsert,
    x_admin_token: str | None = Header(default=None),
) -> dict:
    require_admin_token(x_admin_token)

    try:
        identifier, identifier_type, institution, identity_key = normalize_identity(payload)
    except ValueError as exc:
        detail = "Matricula invalida" if str(exc) == "matricula_invalida" else "CPF invalido"
        raise HTTPException(status_code=400, detail=detail)

    # Matricula e aceita somente para alunos da UNIVESP nesta homologacao.
    if identifier_type == "matricula" and payload.role != "aluno":
        raise HTTPException(status_code=400, detail="Matricula permitida somente para aluno UNIVESP")

    with db(immediate=True) as con:
        con.execute(
            """
            INSERT INTO people(cpf, identifier, identifier_type, institution, name, role, active, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cpf) DO UPDATE SET
                identifier=excluded.identifier,
                identifier_type=excluded.identifier_type,
                institution=excluded.institution,
                name=excluded.name,
                role=excluded.role,
                active=excluded.active,
                updated_at=excluded.updated_at
            """,
            (
                identity_key, identifier, identifier_type, institution,
                payload.name.strip(), payload.role, int(payload.active),
                now_iso(), now_iso(),
            ),
        )

    return {
        "ok": True,
        "identifier": identifier,
        "identifier_type": identifier_type,
        "institution": institution,
        "name": payload.name.strip(),
        "role": payload.role,
        "active": payload.active,
    }


@app.delete("/admin/people/{cpf}")
def delete_person(
    cpf: str,
    x_admin_token: str | None = Header(default=None),
) -> dict:
    require_admin_token(x_admin_token)

    normalized = normalize_cpf(cpf)

    with db(immediate=True) as con:
        active = con.execute(
            """
            SELECT 1
            FROM sessions
            WHERE cpf=? AND status='ACTIVE'
            LIMIT 1
            """,
            (normalized,),
        ).fetchone()

        if active is not None:
            raise HTTPException(
                status_code=409,
                detail="usuario possui sessao ativa",
            )

        cur = con.execute(
            "DELETE FROM people WHERE cpf=?",
            (normalized,),
        )

    return {"ok": True, "deleted": cur.rowcount > 0}


@app.get("/admin/sessions/online")
def online_sessions(
    x_admin_token: str | None = Header(default=None),
) -> list[dict]:
    require_admin_token(x_admin_token)

    with db(immediate=True) as con:
        expire_stale_sessions(con)
        rows = con.execute(
            """
            SELECT
                session_id, cpf, name, role, windows_account,
                computer, ip, mac, login_at, last_seen, action
            FROM sessions
            WHERE status='ACTIVE'
            ORDER BY computer, name
            """
        ).fetchall()

    return [dict(row) for row in rows]


@app.get("/admin/sessions/history")
def session_history(
    limit: int = 200,
    x_admin_token: str | None = Header(default=None),
) -> list[dict]:
    require_admin_token(x_admin_token)
    limit = max(1, min(limit, 2000))

    with db() as con:
        rows = con.execute(
            """
            SELECT
                session_id, cpf, name, role, windows_account,
                computer, ip, mac, status, action,
                login_at, last_seen, logout_at, logout_reason
            FROM sessions
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [dict(row) for row in rows]


@app.get("/admin/events")
def session_events(
    limit: int = 300,
    x_admin_token: str | None = Header(default=None),
) -> list[dict]:
    require_admin_token(x_admin_token)
    limit = max(1, min(limit, 3000))

    with db() as con:
        rows = con.execute(
            """
            SELECT
                session_id, event_type,
                actor_cpf, actor_name, actor_role,
                computer, details, created_at
            FROM session_events
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [dict(row) for row in rows]

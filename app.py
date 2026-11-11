#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import secrets
import sqlite3
import subprocess
import time
from datetime import date, datetime, timezone
from functools import wraps
from pathlib import Path
from threading import Lock
from typing import Any, Callable

from flask import Flask, g, jsonify, render_template, request, session
from werkzeug.security import check_password_hash, generate_password_hash

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
DOMAIN_RE = re.compile(r"^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$")
ALLOWED_STATES = {"active", "suspended"}
SERVICES = [
    {"name": "OpenSSH", "ports": "22", "management": "read-only / not connected"},
    {"name": "Dropbear", "ports": "2222", "management": "read-only / not connected"},
    {"name": "WebSocket dispatcher", "ports": "80, 8080, 8880", "management": "read-only / not connected"},
    {"name": "UDP gateway", "ports": "7300", "management": "read-only / not connected"},
    {"name": "Connection limiter", "ports": "—", "management": "read-only / not connected"},
]
_login_attempts: dict[str, list[float]] = {}
_login_lock = Lock()


def create_app(test_config: dict[str, Any] | None = None) -> Flask:
    app = Flask(__name__, template_folder="templates", static_folder="static")
    app.config.update(
        SECRET_KEY=os.environ.get("SECRET_KEY"),
        DATABASE=os.environ.get("DATABASE_PATH", str(Path(__file__).with_name("bluecompany.db"))),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.environ.get("COOKIE_SECURE", "0") == "1",
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    if test_config:
        app.config.update(test_config)
    if not app.config.get("SECRET_KEY"):
        raise RuntimeError("Set SECRET_KEY to a long, random value before starting the panel.")

    def connect_db() -> sqlite3.Connection:
        conn = sqlite3.connect(app.config["DATABASE"])
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def init_db() -> None:
        Path(app.config["DATABASE"]).parent.mkdir(parents=True, exist_ok=True)
        conn = connect_db()
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS admins (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS customers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL UNIQUE,
                max_sessions INTEGER NOT NULL CHECK(max_sessions BETWEEN 1 AND 100),
                expires_on TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('active', 'suspended')),
                notes TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tls_settings (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                domain TEXT NOT NULL DEFAULT '',
                cert_path TEXT NOT NULL DEFAULT '',
                key_path TEXT NOT NULL DEFAULT '',
                port INTEGER NOT NULL DEFAULT 3129,
                enabled INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                target TEXT NOT NULL,
                detail TEXT NOT NULL
            );
            """
        )
        admin_name = os.environ.get("ADMIN_USERNAME", "").strip()
        admin_password = os.environ.get("ADMIN_PASSWORD", "")
        if admin_name and admin_password and USERNAME_RE.fullmatch(admin_name):
            existing = conn.execute("SELECT id FROM admins WHERE username = ?", (admin_name,)).fetchone()
            if not existing:
                conn.execute(
                    "INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)",
                    (admin_name, generate_password_hash(admin_password), utc_now()),
                )
        conn.execute(
            "INSERT OR IGNORE INTO tls_settings (id, domain, cert_path, key_path, port, enabled, updated_at) VALUES (1, '', '', '', 3129, 0, ?)",
            (utc_now(),),
        )
        conn.commit()
        conn.close()

    def utc_now() -> str:
        return datetime.now(timezone.utc).isoformat(timespec="seconds")

    def audit(action: str, target: str, detail: str = "") -> None:
        conn = connect_db()
        conn.execute(
            "INSERT INTO audit_log (occurred_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)",
            (utc_now(), session.get("admin", "system"), action, target, detail[:500]),
        )
        conn.commit()
        conn.close()

    def json_error(message: str, status: int = 400):
        return jsonify({"ok": False, "error": message}), status

    def require_admin(view: Callable):
        @wraps(view)
        def wrapped(*args, **kwargs):
            if not session.get("admin"):
                return json_error("Inicia sesión para continuar.", 401)
            if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
                supplied = request.headers.get("X-CSRF-Token", "")
                expected = session.get("csrf_token", "")
                if not expected or not secrets.compare_digest(supplied, expected):
                    return json_error("Token CSRF inválido. Actualiza la página e inténtalo otra vez.", 403)
            return view(*args, **kwargs)
        return wrapped

    def read_payload() -> dict[str, Any] | None:
        value = request.get_json(silent=True)
        return value if isinstance(value, dict) else None

    def clean_customer_payload(payload: dict[str, Any], partial: bool = False):
        allowed = {"username", "max_sessions", "expires_on", "status", "notes"}
        if set(payload) - allowed:
            return None, "Hay campos no permitidos."
        required = {"username", "max_sessions", "expires_on", "status"}
        if not partial and not required.issubset(payload):
            return None, "Completa usuario, límite, vencimiento y estado."
        cleaned: dict[str, Any] = {}
        if "username" in payload:
            username = payload["username"]
            if not isinstance(username, str) or not USERNAME_RE.fullmatch(username.strip()):
                return None, "El usuario debe tener 1–32 letras, números, guiones o guiones bajos."
            cleaned["username"] = username.strip()
        if "max_sessions" in payload:
            limit = payload["max_sessions"]
            if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
                return None, "El límite debe ser un entero entre 1 y 100."
            cleaned["max_sessions"] = limit
        if "expires_on" in payload:
            expiry = payload["expires_on"]
            try:
                date.fromisoformat(expiry)
            except (TypeError, ValueError):
                return None, "La fecha debe tener formato YYYY-MM-DD."
            cleaned["expires_on"] = expiry
        if "status" in payload:
            status = payload["status"]
            if status not in ALLOWED_STATES:
                return None, "Estado inválido."
            cleaned["status"] = status
        if "notes" in payload:
            notes = payload["notes"]
            if not isinstance(notes, str) or len(notes) > 500:
                return None, "Las notas deben tener como máximo 500 caracteres."
            cleaned["notes"] = notes.strip()
        return cleaned, None

    def validate_tls_pair(domain: str, cert_path: str, key_path: str) -> tuple[bool, str | None]:
        if not DOMAIN_RE.fullmatch(domain):
            return False, "El dominio es inválido."
        for label, value in (("certificado", cert_path), ("clave", key_path)):
            if not value or not Path(value).is_file() or not os.access(value, os.R_OK):
                return False, f"No se puede leer la ruta del {label}."
        try:
            check = subprocess.run(
                ["openssl", "x509", "-in", cert_path, "-noout", "-checkhost", domain],
                capture_output=True,
                text=True,
                check=False,
            )
            if check.returncode != 0:
                return False, "El certificado no es válido para ese dominio."
            cert_pub = subprocess.run(
                ["openssl", "x509", "-in", cert_path, "-pubkey", "-noout"],
                capture_output=True,
                text=True,
                check=False,
            )
            key_pub = subprocess.run(
                ["openssl", "pkey", "-in", key_path, "-pubout"],
                capture_output=True,
                text=True,
                check=False,
            )
            if cert_pub.returncode != 0 or key_pub.returncode != 0:
                return False, "No se pudo validar la pareja de claves."
            cert_hash = subprocess.run(
                ["openssl", "pkey", "-pubin", "-in", "/dev/stdin", "-outform", "DER"],
                input=cert_pub.stdout,
                capture_output=True,
                text=False,
                check=False,
            )
            key_hash = subprocess.run(
                ["openssl", "pkey", "-pubin", "-in", "/dev/stdin", "-outform", "DER"],
                input=key_pub.stdout,
                capture_output=True,
                text=False,
                check=False,
            )
            if cert_hash.returncode != 0 or key_hash.returncode != 0:
                return False, "La clave y el certificado no coinciden."
            if cert_hash.stdout != key_hash.stdout:
                return False, "El certificado y la clave privada no forman un par válido."
        except FileNotFoundError:
            return False, "El binario OpenSSL no está disponible en este sistema."
        return True, None

    def get_tls_settings() -> dict[str, Any]:
        conn = connect_db()
        row = conn.execute(
            "SELECT domain, cert_path, key_path, port, enabled, updated_at FROM tls_settings WHERE id = 1"
        ).fetchone()
        conn.close()
        if not row:
            return {"domain": "", "cert_path": "", "key_path": "", "port": 3129, "enabled": False, "updated_at": utc_now()}
        return dict(row)

    init_db()

    @app.after_request
    def security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "same-origin"
        response.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
        return response

    @app.route("/")
    def index():
        return render_template("index.html")

    @app.route("/api/session")
    def api_session():
        return jsonify({"logged_in": bool(session.get("admin")), "user": session.get("admin"), "csrf_token": session.get("csrf_token")})

    @app.route("/api/login", methods=["POST"])
    def api_login():
        payload = read_payload()
        if payload is None:
            return json_error("Envía un objeto JSON.")
        username = payload.get("username", "")
        password = payload.get("password", "")
        if not isinstance(username, str) or not isinstance(password, str) or not username or not password:
            return json_error("Usuario y contraseña son obligatorios.")
        remote = request.remote_addr or "unknown"
        now = time.time()
        with _login_lock:
            attempts = [t for t in _login_attempts.get(remote, []) if now - t < 300]
            if len(attempts) >= 10:
                _login_attempts[remote] = attempts
                return json_error("Demasiados intentos. Espera cinco minutos.", 429)
            attempts.append(now)
            _login_attempts[remote] = attempts
        conn = connect_db()
        row = conn.execute("SELECT username, password_hash FROM admins WHERE username = ?", (username,)).fetchone()
        conn.close()
        if not row or not check_password_hash(row["password_hash"], password):
            return json_error("Credenciales incorrectas.", 401)
        session.clear()
        session["admin"] = row["username"]
        session["csrf_token"] = secrets.token_urlsafe(32)
        with _login_lock:
            _login_attempts.pop(remote, None)
        audit("login", row["username"], "Inicio de sesión correcto")
        return jsonify({"ok": True, "user": row["username"], "csrf_token": session["csrf_token"]})

    @app.route("/api/logout", methods=["POST"])
    @require_admin
    def api_logout():
        audit("logout", session["admin"], "Cierre de sesión")
        session.clear()
        return jsonify({"ok": True})

    @app.route("/api/dashboard")
    @require_admin
    def api_dashboard():
        conn = connect_db()
        totals = conn.execute(
            "SELECT COUNT(*) AS total, SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) AS active FROM customers"
        ).fetchone()
        upcoming = conn.execute(
            "SELECT id, username, expires_on, status FROM customers WHERE expires_on >= ? ORDER BY expires_on LIMIT 5",
            (date.today().isoformat(),),
        ).fetchall()
        recent = conn.execute(
            "SELECT occurred_at, actor, action, target, detail FROM audit_log ORDER BY id DESC LIMIT 8"
        ).fetchall()
        tls = conn.execute("SELECT domain, port, enabled FROM tls_settings WHERE id = 1").fetchone()
        conn.close()
        return jsonify({
            "mode": "metadata-only",
            "users": {"total": totals["total"] or 0, "active": totals["active"] or 0},
            "services": SERVICES,
            "upcoming_expirations": [dict(row) for row in upcoming],
            "recent_activity": [dict(row) for row in recent],
            "tls": {"domain": tls["domain"] if tls else "", "port": (tls["port"] if tls else 3129), "enabled": bool((tls["enabled"] if tls else 0))},
            "notice": "Sin conexión al sistema operativo; no se consultan métricas ni sesiones reales.",
        })

    @app.route("/api/users", methods=["GET", "POST"])
    @require_admin
    def api_users():
        if request.method == "GET":
            conn = connect_db()
            rows = conn.execute("SELECT id, username, max_sessions, expires_on, status, notes, created_at, updated_at FROM customers ORDER BY username").fetchall()
            conn.close()
            return jsonify([dict(row) for row in rows])
        payload = read_payload()
        if payload is None:
            return json_error("Envía un objeto JSON.")
        data, error = clean_customer_payload(payload)
        if error:
            return json_error(error)
        now = utc_now()
        conn = connect_db()
        try:
            conn.execute(
                "INSERT INTO customers (username, max_sessions, expires_on, status, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (data["username"], data["max_sessions"], data["expires_on"], data["status"], data.get("notes", ""), now, now),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            conn.close()
            return json_error("Ese usuario ya está registrado.", 409)
        conn.close()
        audit("customer.create", data["username"], "Registro de cuenta de panel (no es un usuario Linux)")
        return jsonify({"ok": True}), 201

    @app.route("/api/users/<int:user_id>", methods=["PUT", "DELETE"])
    @require_admin
    def api_user_detail(user_id: int):
        conn = connect_db()
        old = conn.execute("SELECT username FROM customers WHERE id = ?", (user_id,)).fetchone()
        if not old:
            conn.close()
            return json_error("Usuario no encontrado.", 404)
        if request.method == "DELETE":
            conn.execute("DELETE FROM customers WHERE id = ?", (user_id,))
            conn.commit()
            conn.close()
            audit("customer.delete", old["username"], "Registro eliminado del panel; no se modifica el sistema operativo")
            return jsonify({"ok": True})
        payload = read_payload()
        if payload is None:
            conn.close()
            return json_error("Envía un objeto JSON.")
        data, error = clean_customer_payload(payload, partial=True)
        if error or not data:
            conn.close()
            return json_error(error or "No hay cambios para guardar.")
        data["updated_at"] = utc_now()
        assignments = ", ".join(f"{key} = ?" for key in data)
        try:
            conn.execute(f"UPDATE customers SET {assignments} WHERE id = ?", (*data.values(), user_id))
            conn.commit()
        except sqlite3.IntegrityError:
            conn.close()
            return json_error("Ese nombre de usuario ya existe.", 409)
        conn.close()
        audit("customer.update", data.get("username", old["username"]), "Metadatos actualizados")
        return jsonify({"ok": True})

    @app.route("/api/services")
    @require_admin
    def api_services():
        return jsonify(SERVICES)

    @app.route("/api/logs")
    @require_admin
    def api_logs():
        conn = connect_db()
        rows = conn.execute("SELECT occurred_at, actor, action, target, detail FROM audit_log ORDER BY id DESC LIMIT 100").fetchall()
        conn.close()
        return jsonify([dict(row) for row in rows])

    @app.route("/api/tls", methods=["GET", "POST"])
    @require_admin
    def api_tls():
        if request.method == "GET":
            return jsonify(get_tls_settings())
        payload = read_payload()
        if payload is None:
            return json_error("Envía un objeto JSON.")
        domain = str(payload.get("domain", "")).strip()
        cert_path = str(payload.get("cert_path", "")).strip()
        key_path = str(payload.get("key_path", "")).strip()
        port = int(payload.get("port", 3129) or 3129)
        if not DOMAIN_RE.fullmatch(domain):
            return json_error("El dominio del certificado es inválido.")
        if port not in (3128, 3129, 443):
            return json_error("El puerto TLS debe ser 3128, 3129 o 443.")
        ok, reason = validate_tls_pair(domain, cert_path, key_path)
        if not ok:
            return json_error(reason or "La pareja de certificados no es válida.")
        now = utc_now()
        conn = connect_db()
        conn.execute(
            "INSERT INTO tls_settings (id, domain, cert_path, key_path, port, enabled, updated_at) VALUES (1, ?, ?, ?, ?, 0, ?) ON CONFLICT(id) DO UPDATE SET domain = excluded.domain, cert_path = excluded.cert_path, key_path = excluded.key_path, port = excluded.port, updated_at = excluded.updated_at",
            (domain, cert_path, key_path, port, now),
        )
        conn.commit()
        conn.close()
        audit("tls.saved", domain, f"Ruta del certificado validada para puerto {port}")
        return jsonify({"ok": True, "domain": domain, "cert_path": cert_path, "key_path": key_path, "port": port, "enabled": False})

    @app.route("/api/tls/apply", methods=["POST"])
    @require_admin
    def api_tls_apply():
        payload = read_payload()
        if payload is None:
            return json_error("Envía un objeto JSON.")
        domain = str(payload.get("domain", "")).strip()
        cert_path = str(payload.get("cert_path", "")).strip()
        key_path = str(payload.get("key_path", "")).strip()
        port = int(payload.get("port", 3129) or 3129)
        ok, reason = validate_tls_pair(domain, cert_path, key_path)
        if not ok:
            return json_error(reason or "La pareja de certificados no es válida.")
        cmd = ["sudo", "/opt/blue-company-web/deploy/configure-https-3129.sh", domain, "--cert", cert_path, "--key", key_path, "--port", str(port)]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except FileNotFoundError:
            return json_error("No está disponible el comando sudo para aplicar TLS.")
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Error no especificado.").strip()
            return json_error(f"La configuración TLS falló: {err}")
        conn = connect_db()
        conn.execute(
            "INSERT INTO tls_settings (id, domain, cert_path, key_path, port, enabled, updated_at) VALUES (1, ?, ?, ?, ?, 1, ?) ON CONFLICT(id) DO UPDATE SET domain = excluded.domain, cert_path = excluded.cert_path, key_path = excluded.key_path, port = excluded.port, enabled = 1, updated_at = excluded.updated_at",
            (domain, cert_path, key_path, port, utc_now()),
        )
        conn.commit()
        conn.close()
        audit("tls.apply", domain, f"TLS activado en puerto {port}")
        return jsonify({"ok": True, "domain": domain, "port": port, "enabled": True, "output": (proc.stdout or "").strip()})

    @app.errorhandler(413)
    def request_too_large(_error):
        return json_error("La solicitud es demasiado grande.", 413)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8000")), debug=False)

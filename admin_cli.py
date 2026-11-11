#!/usr/bin/env python3
"""Reset BLUE COMPANY panel admin credentials from a trusted SSH shell.

This changes only the web-panel administrator record in SQLite. It does not
change Linux, SSH, VPN, or customer-account credentials.
"""
from __future__ import annotations

import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from getpass import getpass
from pathlib import Path

from werkzeug.security import generate_password_hash

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
DB_PATH = Path(os.environ.get("DATABASE_PATH", str(Path(__file__).with_name("bluecompany.db"))))


def main() -> int:
    if not sys.stdin.isatty():
        print("Error: ejecuta este comando desde una terminal SSH interactiva.", file=sys.stderr)
        return 2
    if not DB_PATH.is_file():
        print(f"No se encontró la base de datos del panel: {DB_PATH}", file=sys.stderr)
        print("Arranca primero el panel o define DATABASE_PATH.", file=sys.stderr)
        return 1

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        admins = conn.execute("SELECT id, username FROM admins ORDER BY username").fetchall()
        if not admins:
            print("No hay administradores registrados. Configura ADMIN_USERNAME y ADMIN_PASSWORD y arranca el panel.", file=sys.stderr)
            return 1
        print("Administradores del panel:")
        for admin in admins:
            print(f"  - {admin['username']}")
        current = input("Administrador que deseas cambiar: ").strip()
        admin = conn.execute("SELECT id, username FROM admins WHERE username = ?", (current,)).fetchone()
        if not admin:
            print("No existe ese administrador.", file=sys.stderr)
            return 1

        new_username = input(f"Nuevo usuario [{current}]: ").strip() or current
        if not USERNAME_RE.fullmatch(new_username):
            print("El usuario debe tener 1–32 letras, números, guiones o guiones bajos.", file=sys.stderr)
            return 2
        other = conn.execute("SELECT id FROM admins WHERE username = ? AND id != ?", (new_username, admin["id"])).fetchone()
        if other:
            print("Ese nombre ya pertenece a otro administrador.", file=sys.stderr)
            return 2

        password = getpass("Nueva contraseña (mínimo 12 caracteres): ")
        confirmation = getpass("Repite la nueva contraseña: ")
        if len(password) < 12:
            print("La contraseña debe tener al menos 12 caracteres.", file=sys.stderr)
            return 2
        if password != confirmation:
            print("Las contraseñas no coinciden.", file=sys.stderr)
            return 2

        password_hash = generate_password_hash(password)
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("UPDATE admins SET username = ?, password_hash = ? WHERE id = ?", (new_username, password_hash, admin["id"]))
        conn.execute(
            "INSERT INTO audit_log (occurred_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)",
            (now, admin["username"], "security.admin_credentials_changed", new_username, "Credenciales actualizadas desde consola SSH"),
        )
        conn.commit()
        try:
            os.chmod(DB_PATH, 0o600)
        except OSError:
            pass
        print(f"Credenciales del panel actualizadas para '{new_username}'.")
        print("Cierra las sesiones del navegador e inicia sesión de nuevo.")
        return 0
    except sqlite3.Error as error:
        conn.rollback()
        print(f"Error de base de datos: {error}", file=sys.stderr)
        return 1
    except (EOFError, KeyboardInterrupt):
        conn.rollback()
        print("\nOperación cancelada.", file=sys.stderr)
        return 130
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Change BLUE COMPANY web-panel admin credentials from trusted SSH terminal."""
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
        print("Error: ejecuta desde una terminal SSH interactiva.", file=sys.stderr)
        return 2
    if not DB_PATH.is_file():
        print(f"No se encontró la base de datos: {DB_PATH}", file=sys.stderr)
        return 1
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        admins = conn.execute("SELECT id, username FROM admins ORDER BY username").fetchall()
        if not admins:
            print("No hay administradores. Instala/inicia el panel primero.", file=sys.stderr)
            return 1
        print("Administradores del panel:")
        for admin in admins:
            print(f" - {admin['username']}")
        current = input("Administrador que deseas cambiar: ").strip()
        admin = conn.execute("SELECT id, username FROM admins WHERE username = ?", (current,)).fetchone()
        if not admin:
            print("Ese administrador no existe.", file=sys.stderr)
            return 1
        new_username = input(f"Nuevo usuario [{current}]: ").strip() or current
        if not USERNAME_RE.fullmatch(new_username):
            print("Usuario inválido: usa 1–32 letras, números, guion o guion bajo.", file=sys.stderr)
            return 2
        other = conn.execute("SELECT id FROM admins WHERE username = ? AND id != ?", (new_username, admin["id"])).fetchone()
        if other:
            print("Ese usuario ya está asignado.", file=sys.stderr)
            return 2
        password = getpass("Nueva contraseña (mínimo 12 caracteres): ")
        if len(password) < 12 or password != getpass("Repite la contraseña: "):
            print("Contraseña demasiado corta o no coincide.", file=sys.stderr)
            return 2
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("UPDATE admins SET username = ?, password_hash = ? WHERE id = ?", (new_username, generate_password_hash(password), admin["id"]))
        conn.execute(
            "INSERT INTO audit_log (occurred_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)",
            (now, admin["username"], "security.admin_credentials_changed", new_username, "Actualizado desde terminal SSH"),
        )
        conn.commit()
        print(f"Credenciales del panel actualizadas: {new_username}")
        print("No se modificaron usuarios ni contraseñas de Linux/SSH.")
        return 0
    except sqlite3.Error as error:
        conn.rollback()
        print(f"Error SQLite: {error}", file=sys.stderr)
        return 1
    except (EOFError, KeyboardInterrupt):
        conn.rollback()
        print("\nCancelado.", file=sys.stderr)
        return 130
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())

# BLUE COMPANY Web Panel

MVP con una consola web autenticada para mantener **registros administrativos** de clientes, sus límites configurados, vencimientos y notas, además de inventario informativo de servicios y auditoría.

## Alcance actual

Esta versión no administra cuentas Linux/SSH, no aprovisiona túneles, no inspecciona conexiones o memoria de procesos y no inicia/detiene ni instala servicios. El estado de servicios es solo un catálogo de referencia. Los límites son metadatos; no se aplican a sesiones reales. Esto mantiene el panel aislado de operaciones privilegiadas mientras se desarrolla la aplicación.

Incluye login con hash de contraseña, cookies de sesión HTTP-only, protección CSRF para cambios, limitación básica de intentos de login, validación de datos, SQLite y registros de auditoría.

## Requisitos y ejecución local

Python 3.10+:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
export SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export ADMIN_USERNAME="admin"
export ADMIN_PASSWORD="pon-una-clave-larga-y-unica"
flask --app app run --host 127.0.0.1 --port 8000
```

Abre `http://127.0.0.1:8000`. La cuenta administrativa se crea al iniciar por primera vez si se proporcionan las variables de entorno. No hay credenciales predeterminadas. Conserva la misma `SECRET_KEY` entre reinicios. Para HTTPS detrás de un proxy confiable, configura `COOKIE_SECURE=1`.

También se puede usar `python app.py`. La base de datos se crea en `bluecompany.db`; configura `DATABASE_PATH` para cambiar su ubicación.

## Producción

No expongas el servidor de desarrollo de Flask a Internet. Antes de desplegar, configura HTTPS, firewall, copias de seguridad, secretos fuera del repositorio y un servidor WSGI de producción (por ejemplo, Gunicorn). Revisa permisos del archivo SQLite y rota las claves ante cualquier filtración.

Una futura integración con un VPS necesita diseño y revisión de seguridad aparte. No conectes una API web a una shell ni aceptes comandos arbitrarios; cualquier operación privilegiada debería quedar aislada, tener permisos mínimos y requerir controles explícitos.

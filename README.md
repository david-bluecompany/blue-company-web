# BLUE COMPANY Web Panel

MVP con una consola web autenticada para mantener registros administrativos de clientes: límites configurados, vencimientos y notas, junto con un inventario informativo de servicios y auditoría.

## Alcance actual

Esta versión no administra cuentas Linux/SSH, no aprovisiona túneles, no inspecciona conexiones o memoria de procesos y no inicia/detiene ni instala servicios. El estado de servicios es solo un catálogo de referencia; los límites son metadatos y no se aplican a sesiones reales.

Incluye login con hash de contraseña, cookies de sesión HTTP-only, protección CSRF para cambios, limitación básica de intentos de login, validación de datos, SQLite y auditoría.

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

Abre `http://127.0.0.1:8000`. La cuenta administrativa se crea al iniciar por primera vez si se proporcionan las variables de entorno. No hay credenciales predeterminadas. Conserva la misma `SECRET_KEY` entre reinicios. Configura `COOKIE_SECURE=1` cuando el sitio esté servido exclusivamente por HTTPS.

La base de datos se crea en `bluecompany.db`; configura `DATABASE_PATH` para cambiar su ubicación.

## Cambiar usuario y contraseña por SSH

Conéctate por SSH al servidor con una cuenta autorizada para administrar la instalación y ejecuta el comando desde el directorio del proyecto:

```bash
. .venv/bin/activate
python admin_cli.py
```

El comando solicita el administrador existente, el nuevo nombre y la contraseña dos veces usando entrada oculta. Guarda solo el hash de la contraseña, registra la operación en auditoría y no acepta la contraseña como argumento de línea de comandos. Para una base de datos en otra ubicación, usa el mismo `DATABASE_PATH` configurado para el servicio del panel.

Este procedimiento modifica las credenciales del **panel web**. No cambia la cuenta Linux/SSH ni las cuentas cliente. Restringe el acceso SSH y protege la base SQLite: una persona con privilegios de sistema sobre el servidor puede administrar el panel.

## Producción

No expongas el servidor de desarrollo de Flask a Internet. Antes de desplegar, configura HTTPS, firewall, copias de seguridad, secretos fuera del repositorio y un servidor WSGI de producción (por ejemplo, Gunicorn). Revisa permisos del archivo SQLite y rota las claves ante cualquier filtración.

Una futura integración con un VPS necesita diseño y revisión de seguridad aparte. No conectes una API web a una shell ni aceptes comandos arbitrarios; cualquier operación privilegiada debería quedar aislada, contar con permisos mínimos y requerir controles explícitos.

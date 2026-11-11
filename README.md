# BLUE COMPANY Web Panel

MVP con consola administrativa autenticada para gestionar registros de clientes (límites configurados, vencimientos y notas), inventario informativo de servicios y auditoría.

## Alcance actual

Esta versión no administra cuentas Linux/SSH, no aprovisiona túneles, no inspecciona conexiones ni memoria de procesos y no inicia/detiene ni instala servicios. El estado de servicios es un catálogo de referencia; los límites son metadatos y no se aplican a sesiones reales.

Incluye login con hash de contraseña, cookies de sesión HTTP-only, protección CSRF para cambios, limitación básica de intentos de login, validación de datos, SQLite y auditoría. `admin_cli.py` permite cambiar el usuario/contraseña del **panel** desde una sesión SSH autorizada.

## Instalar en una VPS Ubuntu (incluido Ubuntu 26.04)

Conéctate por SSH, instala Git y clona el proyecto:

```bash
sudo apt update
sudo apt install -y git
 git clone https://github.com/david-bluecompany/blue-company-web.git
cd blue-company-web
sudo bash deploy/install-ubuntu.sh
```

El instalador pregunta el usuario y contraseña iniciales. La contraseña debe tener al menos 16 caracteres; se oculta al escribir, se guarda inicialmente en un archivo de entorno protegido solo para inicializar el hash y se elimina de ese archivo después del primer arranque. No hay credenciales predeterminadas.

La aplicación corre como usuario de sistema sin privilegios, con Gunicorn y systemd, enlazada exclusivamente a `127.0.0.1:8000`. No abre puertos, no cambia reglas de firewall ni configura SSH, Nginx o TLS.

### Abrir el panel de forma segura

Desde tu computadora, crea un túnel SSH:

```bash
ssh -L 8000:127.0.0.1:8000 USUARIO_SSH@IP_DE_TU_VPS
```

Mantén esa sesión SSH abierta y visita `http://127.0.0.1:8000` en tu navegador. Así no hace falta publicar el puerto del panel en Internet.

### Cambiar usuario y contraseña del panel por SSH

En la VPS:

```bash
cd /opt/blue-company-web
sudo env DATABASE_PATH=/var/lib/blue-company/bluecompany.db /opt/blue-company-web/.venv/bin/python admin_cli.py
```

El comando pide el administrador existente, el nuevo nombre y la contraseña dos veces usando entrada oculta. Guarda solo el hash, registra el cambio y no modifica las credenciales Linux/SSH ni las de clientes.

### Operación básica

```bash
sudo systemctl status blue-company-web
sudo journalctl -u blue-company-web -f
sudo systemctl restart blue-company-web
```

## Desarrollo local

Python 3.10+:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt gunicorn
export SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export ADMIN_USERNAME="admin"
export ADMIN_PASSWORD="pon-una-clave-larga-y-unica"
flask --app app run --host 127.0.0.1 --port 8000
```

La cuenta administrativa se crea al iniciar por primera vez si se proporcionan las variables de entorno. Conserva la misma `SECRET_KEY` entre reinicios. La base está en `bluecompany.db`; `DATABASE_PATH` la puede cambiar.

## Producción y limitaciones

El instalador configura un servicio local, no una publicación web pública. Para permitir acceso público se requiere dominio, HTTPS, proxy inverso y reglas de red cuidadosamente revisadas; no expongas el servidor de desarrollo de Flask. Protege la base SQLite y los secretos, mantén Ubuntu actualizado y respalda la base.

Este MVP **no es aún un reemplazo de 3X-UI ni ejecuta las funciones privilegiadas del script original**. Una integración posterior con el sistema operativo debe diseñarse aparte: sin shell accesible desde la API, con agente aislado, permisos mínimos, acciones permitidas explícitamente, auditoría y revisión de seguridad.

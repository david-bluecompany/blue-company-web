# BLUE COMPANY Web Panel

MVP con consola administrativa autenticada para gestionar registros de clientes (límites configurados, vencimientos y notas), inventario informativo de servicios y auditoría.

## Alcance actual

Esta versión no administra cuentas Linux/SSH, no aprovisiona túneles, no inspecciona conexiones ni memoria de procesos y no inicia/detiene ni instala servicios. El estado de servicios es solo un catálogo de referencia; los límites son metadatos y no se aplican a sesiones reales.

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

## HTTPS en el puerto 3128

Para obtener TLS de confianza pública necesitas un dominio DNS que apunte a la VPS. En Oracle Cloud configura reglas de entrada TCP 80 y TCP 3128 en la Network Security Group o Security List; permite también esos puertos en UFW si está activo. El puerto 80 se usa para la validación y renovación de Let's Encrypt; la interfaz se sirve cifrada en 3128.

Después de instalar el panel, ejecuta en la VPS:

```bash
cd blue-company-web
sudo bash deploy/configure-https-3128.sh panel.tudominio.com
```

El script configura Nginx como proxy inverso, solicita y renueva el certificado con Certbot, fuerza cookies seguras y redirige HTTP del dominio al puerto HTTPS 3128. No publica Gunicorn (puerto 8000) y no abre puertos por sí mismo en Oracle Cloud o UFW.

Abre `https://panel.tudominio.com:3128`. Verifica renovación con `sudo certbot renew --dry-run`.

## Cambiar usuario y contraseña del panel por SSH

En la VPS:

```bash
cd /opt/blue-company-web
sudo env DATABASE_PATH=/var/lib/blue-company/bluecompany.db /opt/blue-company-web/.venv/bin/python admin_cli.py
```

El comando pide el administrador existente, el nuevo nombre y la contraseña dos veces usando entrada oculta. Guarda solo el hash, registra el cambio y no modifica las credenciales Linux/SSH ni las de clientes.

## Operación básica

```bash
sudo systemctl status blue-company-web
sudo journalctl -u blue-company-web -f
sudo systemctl restart blue-company-web
sudo systemctl status nginx
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

El instalador no configura Oracle Cloud networking automáticamente. Revisa las reglas de red antes del despliegue. Protege la base SQLite y los secretos, mantén Ubuntu actualizado y respalda la base.

Este MVP **no es aún un reemplazo de 3X-UI ni ejecuta las funciones privilegiadas del script original**. Una integración posterior con el sistema operativo debe diseñarse aparte: sin shell accesible desde la API, con agente aislado, permisos mínimos, acciones permitidas explícitamente, auditoría y revisión de seguridad.

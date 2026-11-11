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

El instalador solicita el usuario y contraseña iniciales. La contraseña debe tener al menos 16 caracteres y se oculta al escribir. No hay credenciales predeterminadas. La aplicación corre como usuario de sistema sin privilegios, con Gunicorn/systemd, enlazada inicialmente a `127.0.0.1:8000`. No se cambian reglas de firewall.

## HTTPS en TCP/3128 sin usar TCP/80 ni TCP/8080

Para HTTPS público de confianza necesitas un dominio DNS que apunte a la VPS. La emisión usa el desafío **DNS-01** de Let's Encrypt: no requiere servidor web ni listeners en 80/8080. Certbot te mostrará un registro TXT `_acme-challenge`; publícalo en el DNS del dominio y confirma cuando se haya propagado.

Después de instalar el panel, desde el directorio clonado ejecuta:

```bash
sudo bash deploy/configure-https-3128.sh panel.tudominio.com
```

El script configura Gunicorn para TLS directo en TCP/3128, activa cookies seguras y no instala/configura Nginx ni modifica reglas de firewall. En Oracle Cloud permite **solo TCP/3128** en la regla de ingreso que elijas. No abras 8000 en público. El script no modifica ni utiliza puertos 80/8080. Asegúrate de que TCP/3128 esté libre antes de empezar.

Visita `https://panel.tudominio.com:3128`.

### Renovación del certificado

El desafío DNS manual no se renueva de forma automática. Antes de que expire, vuelve a ejecutar el comando de configuración, completa el nuevo desafío TXT y el certificado se volverá a copiar al directorio protegido del panel. Para renovación automática se necesitaría integrar un plugin DNS compatible con el proveedor que aloja el dominio y custodiar una credencial API DNS de alcance mínimo; no se configura esa credencial automáticamente.

## Cambiar usuario y contraseña del panel por SSH

En la VPS:

```bash
sudo env DATABASE_PATH=/var/lib/blue-company/bluecompany.db /opt/blue-company-web/.venv/bin/python /opt/blue-company-web/admin_cli.py
```

El comando pide el administrador existente, el nuevo nombre y la contraseña dos veces usando entrada oculta. Guarda solo el hash, registra el cambio y no modifica las credenciales Linux/SSH ni las de clientes.

## Operación básica

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

El instalador HTTPS no configura Oracle Cloud networking automáticamente. Revisa y limita la regla de ingreso a TCP/3128. Protege la base SQLite y secretos, mantén Ubuntu actualizado y respalda la base.

Este MVP **no es aún un reemplazo de 3X-UI ni ejecuta las funciones privilegiadas del script original**. Una integración posterior con el sistema operativo debe diseñarse aparte: sin shell accesible desde la API, con agente aislado, permisos mínimos, acciones permitidas explícitamente, auditoría y revisión de seguridad.

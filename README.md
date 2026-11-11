# BLUE COMPANY Web Panel

MVP instalable para Ubuntu Server: consola administrativa web con registros de clientes, límites y vencimientos configurados, auditoría y autenticación independiente de Linux/SSH. El instalador puede dejar el servicio local y después habilitar HTTPS directo por TCP/3128 con certificado PEM existente o Certbot DNS-01 manual.

## Alcance actual

El panel no ejecuta el script Bash ni administra cuentas Linux/SSH, sesiones SSH reales, firewall o servicios del host. Los clientes y límites son registros de la base de datos de la aplicación; el inventario de servicios es informativo. No es todavía un reemplazo funcional de 3X-UI. Esto evita dar privilegios root al proceso web mientras se completa una integración con el host.

Incluye login con hash de contraseña, cookie HTTP-only/SameSite, protección CSRF para cambios, limitación básica de intentos, validación de datos, SQLite y auditoría. `admin_cli.py` permite rotar las credenciales del panel desde una terminal SSH.

## Instalar en Ubuntu VPS

Clona el repositorio en la VPS:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/david-bluecompany/blue-company-web.git
cd blue-company-web
sudo bash deploy/install-ubuntu.sh
```

El instalador solicita el usuario y una contraseña inicial de 16+ caracteres; la entrada se oculta. No hay credenciales por defecto. Crea el usuario de sistema sin login `bluecompany`, instala Flask/Gunicorn en un virtualenv y configura `blue-company-web.service`. La app escucha solo en `127.0.0.1:8000`; no abre puertos ni cambia firewall. Verifica que el servicio quede activo al terminar.

## HTTPS por 3128, sin usar 80 ni 8080

Requiere un dominio con DNS apuntando a la VPS. Ejecuta:

```bash
sudo bash /opt/blue-company-web/deploy/configure-https-3128.sh panel.tudominio.com
```

El asistente ofrece dos opciones: introducir rutas a un certificado/cadena y clave PEM ya existentes (por ejemplo, los archivos de Certbot), o emitir con Certbot manual DNS-01. Comprueba que el certificado corresponda al dominio y que clave/certificado sean pareja, instala copias con permisos restringidos y reinicia únicamente el servicio del panel.

Abre **solo TCP/3128** en Oracle Cloud Security List/NSG y en UFW si lo usas. El configurador no crea reglas, no instala Nginx, no abre 80/8080 ni 8000. URL: `https://panel.tudominio.com:3128`.

Con DNS-01 manual la renovación es manual. Cuando renueves el certificado, vuelve a ejecutar el asistente con las nuevas rutas PEM. Para renovación automática hay que instalar un plugin DNS del proveedor y limitar cuidadosamente su token API; no se configura esa credencial aquí.

## Cambiar usuario/contraseña del panel por SSH

```bash
sudo env DATABASE_PATH=/var/lib/blue-company/bluecompany.db \
  /opt/blue-company-web/.venv/bin/python /opt/blue-company-web/admin_cli.py
```

Pide el administrador existente, el nuevo nombre y la contraseña dos veces de forma oculta. Persiste solamente el hash y registra auditoría. No toca credenciales de Linux, SSH ni de clientes.

## Revisar y operar

```bash
sudo systemctl status blue-company-web
sudo journalctl -u blue-company-web -n 100 --no-pager
sudo systemctl restart blue-company-web
sudo ss -ltnp | grep ':3128'
```

El puerto 8000 es local; no lo abras en Oracle Cloud. El acceso web público es exclusivamente por 3128 una vez configurado TLS.

## Desarrollo local

Python 3.10+:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt gunicorn
export SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export ADMIN_USERNAME=admin
export ADMIN_PASSWORD='una-clave-larga-de-desarrollo'
flask --app app run --host 127.0.0.1 --port 8000
```

No publiques el servidor de desarrollo Flask. Protege la base SQLite, secretos y respaldos.

## Próximas fases

1. Añadir pruebas automatizadas y validar instalación/HTTPS en Ubuntu limpio.
2. Completar la sección visual de TLS/estado con instrucciones claras de administración.
3. Diseñar por separado un agente local de permisos mínimos para integrar las funciones del script original, con allowlist, auditoría y revisión; nunca ejecutar comandos arbitrarios recibidos de la web.

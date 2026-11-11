#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="blue-company-web"
APP_USER="bluecompany"
APP_GROUP="bluecompany"
APP_DIR="/opt/blue-company-web"
DATA_DIR="/var/lib/blue-company"
ETC_DIR="/etc/blue-company"
ENV_FILE="${ETC_DIR}/panel.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Ejecuta con sudo: sudo bash deploy/install-ubuntu.sh"
[[ -f app.py && -f admin_cli.py && -f requirements.txt && -d templates && -d static && -f deploy/configure-https-3129.sh ]] || fail "Ejecuta desde la raíz del repositorio blue-company-web."
[[ -f /etc/os-release ]] || fail "No se reconoce la distribución."
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail "Este instalador requiere Ubuntu."

printf '\nBLUE COMPANY · Instalación Ubuntu\n'
printf 'Servicio web local en 127.0.0.1:8000. No modifica firewall ni puertos de red.\n\n'
read -r -p "Usuario administrador del panel: " ADMIN_USERNAME
[[ "$ADMIN_USERNAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || fail "Usuario inválido."
read -r -s -p "Contraseña (mínimo 16 caracteres): " ADMIN_PASSWORD; printf '\n'
read -r -s -p "Repite la contraseña: " ADMIN_PASSWORD_CONFIRM; printf '\n'
[[ ${#ADMIN_PASSWORD} -ge 16 ]] || fail "Usa una contraseña de al menos 16 caracteres."
[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] || fail "Las contraseñas no coinciden."
[[ "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* && "$ADMIN_PASSWORD" != *"'"* ]] || fail "No se admiten comillas simples ni saltos de línea en la contraseña inicial."
unset ADMIN_PASSWORD_CONFIRM

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip ca-certificates openssl sudo

if ! getent group "$APP_GROUP" >/dev/null; then groupadd --system "$APP_GROUP"; fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
install -d -o root -g root -m 0755 "$APP_DIR" "$APP_DIR/templates" "$APP_DIR/static" "$APP_DIR/deploy"
install -d -o "$APP_USER" -g "$APP_GROUP" -m 0750 "$DATA_DIR"
install -d -o root -g "$APP_GROUP" -m 0750 "$ETC_DIR"
install -o root -g root -m 0644 app.py admin_cli.py requirements.txt "$APP_DIR/"
install -o root -g root -m 0644 templates/index.html "$APP_DIR/templates/"
install -o root -g root -m 0644 static/styles.css static/app.js "$APP_DIR/static/"
install -o root -g root -m 0755 deploy/configure-https-3129.sh "$APP_DIR/deploy/"

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt" gunicorn

PANEL_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
cat > "$ENV_FILE" <<EOF
SECRET_KEY=${PANEL_SECRET}
DATABASE_PATH=${DATA_DIR}/bluecompany.db
ADMIN_USERNAME='${ADMIN_USERNAME}'
ADMIN_PASSWORD='${ADMIN_PASSWORD}'
COOKIE_SECURE=0
PORT=8000
EOF
unset ADMIN_PASSWORD PANEL_SECRET
chown root:"$APP_GROUP" "$ENV_FILE"
chmod 0640 "$ENV_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=BLUE COMPANY Web Panel
After=network.target
Wants=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8000 --access-logfile - --error-logfile - app:app
Restart=on-failure
RestartSec=3
TimeoutStartSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${DATA_DIR}
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_FILE"

cat > /etc/sudoers.d/bluecompany-web <<EOF
bluecompany ALL=(root) NOPASSWD: /opt/blue-company-web/deploy/configure-https-3129.sh
Defaults:bluecompany !requiretty
EOF
chmod 0440 /etc/sudoers.d/bluecompany-web
visudo -cf /etc/sudoers.d/bluecompany-web >/dev/null || fail "La regla sudoers no es válida."

systemctl daemon-reload
systemctl enable --now "$APP_NAME"
sed -i '/^ADMIN_PASSWORD=/d' "$ENV_FILE"
chmod 0640 "$ENV_FILE"
systemctl restart "$APP_NAME"
systemctl is-active --quiet "$APP_NAME" || fail "El servicio no arrancó. Revisa journalctl -u $APP_NAME."
curl -fsS --max-time 5 http://127.0.0.1:8000/api/session >/dev/null || fail "La verificación local del panel falló."

printf '\nInstalación completada.\n'
printf 'Servicio: sudo systemctl status %s\n' "$APP_NAME"
printf 'Logs:     sudo journalctl -u %s -f\n' "$APP_NAME"
printf 'TLS/3129: sudo bash %s/deploy/configure-https-3129.sh TU_DOMINIO --cert RUTA/fullchain.pem --key RUTA/privkey.pem\n' "$APP_DIR"
printf 'Cambiar credenciales del panel por SSH:\n'
printf '  sudo env DATABASE_PATH=%s %s/.venv/bin/python %s/admin_cli.py\n' "$DATA_DIR/bluecompany.db" "$APP_DIR" "$APP_DIR"

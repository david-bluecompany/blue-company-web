#!/usr/bin/env bash
set -Eeuo pipefail

# Install BLUE COMPANY as an unprivileged systemd service. This does not open
# firewall ports, configure SSH, or grant the web process root privileges.
APP_NAME="blue-company-web"
APP_USER="bluecompany"
APP_GROUP="bluecompany"
APP_DIR="/opt/blue-company-web"
DATA_DIR="/var/lib/blue-company"
ETC_DIR="/etc/blue-company"
ENV_FILE="${ETC_DIR}/panel.env"
SERVICE_FILE="/etc/systemd/system/blue-company-web.service"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Ejecuta con sudo: sudo bash deploy/install-ubuntu.sh"
[[ -f "app.py" && -f "requirements.txt" && -d "templates" && -d "static" ]] || fail "Ejecuta este script desde la raíz del repositorio blue-company-web."
[[ -f /etc/os-release ]] || fail "No se reconoce la distribución."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Este instalador está preparado para Ubuntu (incluido Ubuntu 26.04)."

printf '\nBLUE COMPANY · instalación local segura en Ubuntu\n'
printf 'La app escuchará solo en 127.0.0.1:8000; no cambia el firewall ni configura un dominio.\n\n'

read -r -p "Usuario administrador del panel: " ADMIN_USERNAME
[[ "$ADMIN_USERNAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || fail "Usuario inválido (usa letras, números, guion o guion bajo; máximo 32)."
read -r -s -p "Contraseña (mínimo 16 caracteres): " ADMIN_PASSWORD; printf '\n'
read -r -s -p "Repite la contraseña: " ADMIN_PASSWORD_CONFIRM; printf '\n'
[[ ${#ADMIN_PASSWORD} -ge 16 ]] || fail "La contraseña debe tener al menos 16 caracteres."
[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] || fail "Las contraseñas no coinciden."
[[ "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* && "$ADMIN_PASSWORD" != *"'"* ]] || fail "La contraseña no puede contener comillas simples ni saltos de línea."
unset ADMIN_PASSWORD_CONFIRM

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip ca-certificates

if ! getent group "$APP_GROUP" >/dev/null; then groupadd --system "$APP_GROUP"; fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_GROUP" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
install -d -o root -g root -m 0755 "$APP_DIR"
install -d -o "$APP_USER" -g "$APP_GROUP" -m 0750 "$DATA_DIR"
install -d -o root -g "$APP_GROUP" -m 0750 "$ETC_DIR"
install -d -o root -g root -m 0755 "$APP_DIR/templates" "$APP_DIR/static" "$APP_DIR/deploy"
install -o root -g root -m 0644 app.py requirements.txt "$APP_DIR/"
install -o root -g root -m 0644 templates/index.html "$APP_DIR/templates/"
install -o root -g root -m 0644 static/styles.css static/app.js "$APP_DIR/static/"

python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt" gunicorn

PANEL_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
# Password is entered interactively and quoted for systemd EnvironmentFile.
# Single quotes are excluded above, so no shell/systemd expansion is possible.
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
Type=notify
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
systemctl daemon-reload
systemctl enable --now "$APP_NAME"

# The database has now stored the initial password as a Werkzeug hash. Remove
# the bootstrap secret from the environment file; future restarts do not need it.
sed -i '/^ADMIN_PASSWORD=/d' "$ENV_FILE"
chmod 0640 "$ENV_FILE"
systemctl restart "$APP_NAME"

printf '\nInstalación completada.\n'
printf 'Servicio: systemctl status %s\n' "$APP_NAME"
printf 'Logs:     journalctl -u %s -f\n' "$APP_NAME"
printf 'Local:    http://127.0.0.1:8000\n'
printf '\nAcceso desde tu computadora mediante túnel SSH:\n'
printf '  ssh -L 8000:127.0.0.1:8000 USUARIO_SSH@IP_DE_TU_VPS\n'
printf 'Después abre http://127.0.0.1:8000 en tu navegador.\n'
printf '\nCambiar credenciales del panel por SSH:\n'
printf '  cd %s && sudo env DATABASE_PATH=%s %s/.venv/bin/python admin_cli.py\n' "$APP_DIR" "$DATA_DIR/bluecompany.db" "$APP_DIR"
printf '\nAviso: el MVP guarda registros administrativos; todavía no controla cuentas SSH ni servicios del host.\n'

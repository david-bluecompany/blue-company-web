#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="blue-company-web"
APP_DIR="/opt/blue-company-web"
TLS_DIR="/etc/blue-company/tls"
ENV_FILE="/etc/blue-company/panel.env"
OVERRIDE_DIR="/etc/systemd/system/${APP_NAME}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/https-3129.conf"
PORT="3129"
DOMAIN=""
CERT_SOURCE=""
KEY_SOURCE=""

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "Ejecuta con sudo."
[[ -f /etc/blue-company/panel.env && -x "${APP_DIR}/.venv/bin/gunicorn" ]] || fail "Instala primero BLUE COMPANY."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert) CERT_SOURCE="${2:-}"; shift 2 ;;
    --key) KEY_SOURCE="${2:-}"; shift 2 ;;
    --port) PORT="${2:-3129}"; shift 2 ;;
    *)
      if [[ -z "$DOMAIN" ]]; then DOMAIN="$1"; shift; else shift; fi
      ;;
  esac
done

if [[ -z "$CERT_SOURCE" || -z "$KEY_SOURCE" ]]; then
  read -r -p "Dominio del certificado: " DOMAIN
  read -r -p "Ruta al certificado fullchain.pem: " CERT_SOURCE
  read -r -p "Ruta a la clave privada privkey.pem: " KEY_SOURCE
fi

[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || fail "El dominio es inválido."
[[ -f "$CERT_SOURCE" && -r "$CERT_SOURCE" ]] || fail "No se puede leer el certificado indicado: $CERT_SOURCE"
[[ -f "$KEY_SOURCE" && -r "$KEY_SOURCE" ]] || fail "No se puede leer la clave privada indicada: $KEY_SOURCE"
command -v openssl >/dev/null || fail "Falta openssl. Instálalo con apt."

openssl x509 -in "$CERT_SOURCE" -noout -checkhost "$DOMAIN" >/dev/null || fail "El certificado no es válido para $DOMAIN."
CERT_PUB=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
KEY_PUB=$(openssl pkey -in "$KEY_SOURCE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] || fail "El certificado y la clave privada no forman un par válido."

systemctl stop "$APP_NAME" >/dev/null 2>&1 || true
if ss -H -ltn "( sport = :${PORT} )" | grep -q .; then
  systemctl start "$APP_NAME" >/dev/null 2>&1 || true
  fail "El puerto TCP/${PORT} ya está ocupado. No se modificó el servicio."
fi

install -d -o root -g bluecompany -m 0750 "$TLS_DIR"
install -o root -g bluecompany -m 0640 "$CERT_SOURCE" "$TLS_DIR/fullchain.pem"
install -o root -g bluecompany -m 0640 "$KEY_SOURCE" "$TLS_DIR/privkey.pem"
install -d -o root -g root -m 0755 "$OVERRIDE_DIR"
cat > "$OVERRIDE_FILE" <<EOF
[Service]
ExecStart=
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 2 --bind 0.0.0.0:${PORT} --certfile ${TLS_DIR}/fullchain.pem --keyfile ${TLS_DIR}/privkey.pem --access-logfile - --error-logfile - app:app
EOF
chmod 0644 "$OVERRIDE_FILE"
if grep -q '^COOKIE_SECURE=' "$ENV_FILE"; then
  sed -i "s/^COOKIE_SECURE=.*/COOKIE_SECURE=1/" "$ENV_FILE"
else
  printf '\nCOOKIE_SECURE=1\n' >> "$ENV_FILE"
fi
systemctl daemon-reload
systemctl start "$APP_NAME"
sleep 1
systemctl is-active --quiet "$APP_NAME" || fail "El servicio no arrancó. Revisa journalctl -u $APP_NAME -n 100"
curl --silent --show-error --fail --insecure --max-time 5 "https://127.0.0.1:${PORT}/api/session" >/dev/null || fail "La comprobación HTTPS local falló."

printf '\nHTTPS activo: https://%s:%s\n' "$DOMAIN" "$PORT"
printf 'Abre solo TCP/%s en Oracle Cloud o tu firewall.\n' "$PORT"
printf 'Certificado activo: %s/fullchain.pem\n' "$TLS_DIR"
printf 'Clave privada activa: %s/privkey.pem\n' "$TLS_DIR"

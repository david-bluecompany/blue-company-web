#!/usr/bin/env bash
set -Eeuo pipefail

# Enable public HTTPS directly in Gunicorn on TCP/3128. TLS-ALPN/HTTP
# challenges are intentionally not used: certificate validation is DNS-01,
# so this script does not bind, configure, or change firewall rules for 80/8080.
DOMAIN="${1:-}"
APP_SERVICE="blue-company-web"
APP_DIR="/opt/blue-company-web"
APP_ENV="/etc/blue-company/panel.env"
TLS_DIR="/etc/blue-company/tls"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
OVERRIDE_DIR="/etc/systemd/system/${APP_SERVICE}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/https-3128.conf"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Ejecuta con sudo: sudo bash deploy/configure-https-3128.sh panel.tudominio.com"
[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || fail "Indica un dominio DNS válido; Let's Encrypt DNS-01 requiere un dominio, no una IP."
[[ -f "$APP_ENV" && -x "$APP_DIR/.venv/bin/gunicorn" ]] || fail "Instala primero el panel con deploy/install-ubuntu.sh."
systemctl is-active --quiet "$APP_SERVICE" || fail "El servicio $APP_SERVICE no está activo."
if ss -H -ltn '( sport = :3128 )' | grep -q .; then fail "TCP/3128 ya está ocupado; no se cambiará el servicio que lo usa."; fi

read -r -p "Correo para Let's Encrypt: " EMAIL
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "Correo inválido."
printf '\nSe habilitará HTTPS directo en https://%s:3128 usando validación DNS-01.\n' "$DOMAIN"
printf 'No se configurarán ni abrirán los puertos 80 o 8080. No se modificarán reglas de firewall.\n'
printf 'Asegúrate de crear un registro DNS A para el dominio y permitir TCP/3128 en Oracle Cloud.\n'
read -r -p "¿Continuar? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y certbot ca-certificates

# DNS-01 uses a TXT record at _acme-challenge.<domain>; Certbot prompts for it.
# No HTTP server or listener on ports 80/8080 is installed by this script.
certbot certonly --manual --preferred-challenges dns --key-type ecdsa \
  --agree-tos --email "$EMAIL" --no-eff-email --manual-public-ip-logging-ok \
  -d "$DOMAIN"

[[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || fail "Certbot no dejó un certificado utilizable en $CERT_DIR."
install -d -o root -g bluecompany -m 0750 "$TLS_DIR"
install -o root -g bluecompany -m 0640 "$CERT_DIR/fullchain.pem" "$TLS_DIR/fullchain.pem"
install -o root -g bluecompany -m 0640 "$CERT_DIR/privkey.pem" "$TLS_DIR/privkey.pem"

# Replace only this application's systemd start command. The service remains
# unprivileged; it can read the restricted certificate copy via its group.
install -d -o root -g root -m 0755 "$OVERRIDE_DIR"
cat > "$OVERRIDE_FILE" <<EOF
[Service]
ExecStart=
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 2 --bind 0.0.0.0:3128 --certfile ${TLS_DIR}/fullchain.pem --keyfile ${TLS_DIR}/privkey.pem --access-logfile - --error-logfile - app:app
EOF
chmod 0644 "$OVERRIDE_FILE"
if grep -q '^COOKIE_SECURE=' "$APP_ENV"; then
  sed -i 's/^COOKIE_SECURE=.*/COOKIE_SECURE=1/' "$APP_ENV"
else
  printf '\nCOOKIE_SECURE=1\n' >> "$APP_ENV"
fi
systemctl daemon-reload
systemctl restart "$APP_SERVICE"
sleep 1
systemctl is-active --quiet "$APP_SERVICE" || fail "El panel no arrancó. Revisa: journalctl -u $APP_SERVICE -n 100"
curl --silent --show-error --fail --insecure --max-time 5 https://127.0.0.1:3128/api/session >/dev/null || fail "La verificación HTTPS local falló; revisa los logs del servicio."

printf '\nListo: https://%s:3128\n' "$DOMAIN"
printf 'Abre solo TCP/3128 en Oracle Cloud (y en UFW si lo administras). Este script no toca el firewall.\n'
printf 'Gunicorn sirve TLS directamente; no instala ni configura Nginx.\n'
printf '\nRENOVACIÓN: el método DNS manual requiere renovar y copiar el certificado manualmente.\n'
printf 'Ejecuta nuevamente este script antes de vencer el certificado y completa el nuevo desafío TXT.\n'
printf 'No se alteraron los puertos TCP/80 ni TCP/8080.\n'

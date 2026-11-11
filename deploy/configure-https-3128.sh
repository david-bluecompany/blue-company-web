#!/usr/bin/env bash
set -Eeuo pipefail

# Configure direct HTTPS on TCP/3128 using either existing PEM files or
# Certbot DNS-01. Does not install a proxy, bind port 80/8080, or alter firewall.
DOMAIN="${1:-}"
APP_NAME="blue-company-web"
APP_DIR="/opt/blue-company-web"
TLS_DIR="/etc/blue-company/tls"
OVERRIDE_DIR="/etc/systemd/system/${APP_NAME}.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/https-3128.conf"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "Ejecuta con sudo."
[[ -f /etc/blue-company/panel.env && -x "$APP_DIR/.venv/bin/gunicorn" ]] || fail "Instala primero BLUE COMPANY."
[[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || fail "Indica el dominio que usará el certificado, por ejemplo panel.ejemplo.com."
command -v openssl >/dev/null || fail "Falta openssl. Instálalo con apt."

printf '\nBLUE COMPANY · HTTPS directo en TCP/3128\n'
printf 'No usa 80/8080, no instala Nginx y no modifica firewall/Oracle NSG.\n'
printf 'En Oracle Cloud permite TCP/3128 y apunta el DNS del dominio a esta VPS.\n\n'
printf '[1] Usar certificado y clave PEM existentes (por ejemplo, Certbot)\n'
printf '[2] Solicitar certificado con Certbot manual DNS-01\n'
read -r -p "Selecciona [1/2]: " MODE
case "$MODE" in
  1)
    read -r -p "Ruta a fullchain.pem/certificado PEM: " CERT_SOURCE
    read -r -p "Ruta a privkey.pem/clave privada PEM: " KEY_SOURCE
    [[ -f "$CERT_SOURCE" && -r "$CERT_SOURCE" ]] || fail "No se puede leer el certificado indicado."
    [[ -f "$KEY_SOURCE" && -r "$KEY_SOURCE" ]] || fail "No se puede leer la clave privada indicada."
    ;;
  2)
    read -r -p "Correo para Let's Encrypt: " EMAIL
    [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "Correo inválido."
    apt-get update
    apt-get install -y certbot openssl ca-certificates
    certbot certonly --manual --preferred-challenges dns --key-type ecdsa \
      --cert-name "$DOMAIN" --agree-tos --email "$EMAIL" --no-eff-email \
      --manual-public-ip-logging-ok -d "$DOMAIN"
    CERT_SOURCE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY_SOURCE="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    [[ -f "$CERT_SOURCE" && -f "$KEY_SOURCE" ]] || fail "Certbot no generó el par de archivos esperado."
    ;;
  *) fail "Opción inválida." ;;
esac

openssl x509 -in "$CERT_SOURCE" -noout -checkhost "$DOMAIN" >/dev/null || fail "El certificado no es válido para $DOMAIN."
CERT_PUB=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
KEY_PUB=$(openssl pkey -in "$KEY_SOURCE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
[[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] || fail "El certificado y la clave privada no forman un par."

# Stop only the BLUE COMPANY unit, then ensure the requested port is free.
systemctl stop "$APP_NAME"
if ss -H -ltn '( sport = :3128 )' | grep -q .; then
  systemctl start "$APP_NAME" || true
  fail "TCP/3128 ya está ocupado por otro proceso; no se modificó ese proceso."
fi

install -d -o root -g bluecompany -m 0750 "$TLS_DIR"
install -o root -g bluecompany -m 0640 "$CERT_SOURCE" "$TLS_DIR/fullchain.pem"
install -o root -g bluecompany -m 0640 "$KEY_SOURCE" "$TLS_DIR/privkey.pem"
install -d -o root -g root -m 0755 "$OVERRIDE_DIR"
cat > "$OVERRIDE_FILE" <<EOF
[Service]
ExecStart=
ExecStart=${APP_DIR}/.venv/bin/gunicorn --workers 2 --bind 0.0.0.0:3128 --certfile ${TLS_DIR}/fullchain.pem --keyfile ${TLS_DIR}/privkey.pem --access-logfile - --error-logfile - app:app
EOF
chmod 0644 "$OVERRIDE_FILE"
ENV_FILE="/etc/blue-company/panel.env"
if grep -q '^COOKIE_SECURE=' "$ENV_FILE"; then
  sed -i 's/^COOKIE_SECURE=.*/COOKIE_SECURE=1/' "$ENV_FILE"
else
  printf '\nCOOKIE_SECURE=1\n' >> "$ENV_FILE"
fi
systemctl daemon-reload
systemctl start "$APP_NAME"
sleep 1
if ! systemctl is-active --quiet "$APP_NAME"; then
  echo "El servicio no inició. Revisa: journalctl -u $APP_NAME -n 100" >&2
  exit 1
fi
curl --silent --show-error --fail --insecure --max-time 5 "https://127.0.0.1:3128/api/session" >/dev/null || fail "La comprobación HTTPS local falló."

printf '\nHTTPS activo: https://%s:3128\n' "$DOMAIN"
printf 'Abre solo TCP/3128 en Oracle Cloud (y UFW, si está activo). Este script no toca el firewall.\n'
printf 'Las rutas activas del panel son %s/fullchain.pem y %s/privkey.pem\n' "$TLS_DIR" "$TLS_DIR"
printf 'Para actualizar los certificados, vuelve a ejecutar este configurador con el nuevo par PEM.\n'
printf 'Con DNS-01 manual la renovación es manual; Certbot no puede renovarlo automáticamente sin hooks/API DNS.\n'

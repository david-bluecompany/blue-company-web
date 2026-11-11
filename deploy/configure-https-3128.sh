#!/usr/bin/env bash
set -Eeuo pipefail

# Configure HTTPS through Nginx on TCP/3128 with a Let's Encrypt certificate.
# The Flask/Gunicorn service remains bound to localhost:8000 and unprivileged.
DOMAIN="${1:-}"
APP_SERVICE="blue-company-web"
APP_ENV="/etc/blue-company/panel.env"
SITE="/etc/nginx/sites-available/blue-company-web"
ENABLED="/etc/nginx/sites-enabled/blue-company-web"
WEBROOT="/var/www/letsencrypt"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Ejecuta con sudo: sudo bash deploy/configure-https-3128.sh tu-dominio.example"
[[ "${DOMAIN}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] || fail "Indica un dominio DNS válido como panel.ejemplo.com. Let's Encrypt no emite certificados para una IP privada."
[[ -f "$APP_ENV" ]] || fail "No se encuentra $APP_ENV. Instala primero el panel con deploy/install-ubuntu.sh."
systemctl is-active --quiet "$APP_SERVICE" || fail "El servicio $APP_SERVICE no está activo."
curl -fsS --max-time 3 http://127.0.0.1:8000/api/session >/dev/null || fail "El panel no responde en 127.0.0.1:8000."
if ss -H -ltn '( sport = :3128 )' | grep -q .; then fail "El puerto TCP 3128 ya está ocupado; identifica el servicio antes de continuar."; fi

read -r -p "Correo para avisos de renovación de Let's Encrypt: " EMAIL
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "Correo inválido."
printf '\nSe configurará https://%s:3128 y una redirección HTTP desde el puerto 80.\n' "$DOMAIN"
printf 'Comprueba que el DNS A/AAAA apunta a esta VPS y que Oracle Cloud permite TCP 80 y 3128.\n'
read -r -p "¿Continuar? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot
install -d -o www-data -g www-data -m 0755 "$WEBROOT/.well-known/acme-challenge"

# HTTP-01 validation and redirect for normal traffic. This leaves existing
# unrelated Nginx site files intact; a hostname conflict is rejected by nginx -t.
cat > "$SITE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host:3128\$request_uri;
    }
}
NGINX
ln -sfn "$SITE" "$ENABLED"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --keep-until-expiring

cat > "$SITE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 301 https://\$host:3128\$request_uri; }
}

server {
    listen 3128 ssl;
    listen [::]:3128 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:BLUECOMPANY_TLS:10m;
    ssl_session_tickets off;

    server_tokens off;
    client_max_body_size 64k;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
NGINX

nginx -t
systemctl reload nginx

if grep -q '^COOKIE_SECURE=' "$APP_ENV"; then
  sed -i 's/^COOKIE_SECURE=.*/COOKIE_SECURE=1/' "$APP_ENV"
else
  printf '\nCOOKIE_SECURE=1\n' >> "$APP_ENV"
fi
systemctl restart "$APP_SERVICE"

# Certbot's webroot authenticator renews without stopping Nginx. Reload Nginx
# after successful renewal so it picks up the renewed certificate.
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/blue-company-web-reload-nginx <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/blue-company-web-reload-nginx
systemctl enable --now certbot.timer 2>/dev/null || true

printf '\nTLS configurado. Panel: https://%s:3128\n' "$DOMAIN"
printf 'Comprueba renovación: certbot renew --dry-run\n'
printf 'En Oracle Cloud abre TCP 3128 y TCP 80 en la lista de seguridad/NSG y en UFW si lo usas.\n'
printf 'No abras 8000: Gunicorn continúa limitado a localhost.\n'

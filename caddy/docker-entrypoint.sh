#!/bin/sh
set -e

CADDYFILE_TEMPLATE="/etc/caddy/Caddyfile.template"
CADDYFILE="/etc/caddy/Caddyfile"
CERT_DIR="/certs"

# Validate required domain environment variable
if [ -z "$APP_DOMAIN" ]; then
    echo "ERROR: APP_DOMAIN environment variable is required"
    echo "Set it in your .env file (e.g., APP_DOMAIN=hawkra.local)"
    exit 1
fi

# Determine TLS mode
if [ "$LETS_ENCRYPT" = "true" ]; then
    echo "Let's Encrypt mode — Caddy will auto-provision certificates"
    TLS_LINE=""
elif [ -f "$CERT_DIR/cert.pem" ] && [ -f "$CERT_DIR/key.pem" ]; then
    echo "Custom certificates found in $CERT_DIR — using provided certs"
    TLS_LINE="tls /certs/cert.pem /certs/key.pem"
else
    echo "No custom certificates found — using auto-generated self-signed certs"
    TLS_LINE="tls internal"
fi

# Substitute domain placeholder and TLS directive
sed -e "s|APP_DOMAIN|$APP_DOMAIN|g" \
    -e "s|# TLS_DIRECTIVE|$TLS_LINE|g" \
    "$CADDYFILE_TEMPLATE" > "$CADDYFILE"

echo "Caddy configured for domain: $APP_DOMAIN"

exec caddy run --config "$CADDYFILE" --adapter caddyfile

#!/usr/bin/env bash
# =====================================================================
# 60-nginx-tls.sh — nginx + certificado Let's Encrypt para el panel y
# páginas públicas. Orden seguro:
#   1) Comprueba DNS A -> IP (si no coincide, aborta: certbot fallaría)
#   2) vhost HTTP mínimo, nginx arranca
#   3) certbot obtiene el certificado
#   4) Renderiza el vhost completo TLS + hook de recarga para postfix/dovecot
# Idempotente: si ya hay certificado, solo re-renderiza y recarga.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env
validar_vars FQDN_HOST IP_SERVIDOR CORREO_POSTMASTER PUERTO_MAUTIC_LOCAL
sin_marcadores "$ARCHIVO_ENV"

LIVE_DIR="/etc/letsencrypt/live/${FQDN_HOST}"

echo "Acciones que realizará este script:"
echo "  - Verificar DNS A de ${FQDN_HOST} = ${IP_SERVIDOR}"
echo "  - vhost HTTP + 'certbot certonly --nginx -d ${FQDN_HOST}'"
echo "  - vhost TLS completo hacia Mautic (127.0.0.1:${PUERTO_MAUTIC_LOCAL})"
echo "  - Hook de recarga postfix/dovecot/nginx en renovaciones"
confirmar "¿Continuar?"

# --- 1) DNS obligatorio antes de pedir certificado ---
if command -v dig >/dev/null 2>&1; then
    A_RES=$(dig +short A "$FQDN_HOST" @1.1.1.1 2>/dev/null | tail -1)
    if [ "$A_RES" != "$IP_SERVIDOR" ]; then
        die "DNS A de $FQDN_HOST resuelve '$A_RES' y esperábamos $IP_SERVIDOR.
Publica/corrige el registro A y espera propagación antes de pedir el certificado."
    fi
    echo "  [OK] DNS A correcto"
fi

# --- 2) vhost HTTP mínimo para ACME ---
respaldar_archivo /etc/nginx/sites-available/campanas
cat > /etc/nginx/sites-available/campanas <<EOF
# Vhost temporal solo-HTTP para validar el dominio ante Let's Encrypt.
# Será sustituido por nginx/mautic.conf.plantilla renderizada.
server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN_HOST};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sfn /etc/nginx/sites-available/campanas /etc/nginx/sites-enabled/campanas
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx -t falló con el vhost temporal"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx

# --- 3) Certificado ---
if [ -f "${LIVE_DIR}/fullchain.pem" ]; then
    log_info "Certificado ya existe: no se solicita de nuevo"
else
    log_info "Solicitando certificado Let's Encrypt"
    certbot certonly --nginx -d "$FQDN_HOST" \
        -m "$CORREO_POSTMASTER" --agree-tos --no-eff-email --non-interactive \
        || die "certbot no pudo obtener el certificado (revisa DNS/firewall 80)."
fi
[ -f "${LIVE_DIR}/fullchain.pem" ] || die "El certificado no está en $LIVE_DIR tras certbot"

# --- 4) Vhost completo desde plantilla ---
bash "$DIR_SCRIPTS/renderizar-plantillas.sh" web
nginx -t || die "nginx -t falló con el vhost TLS"
systemctl reload nginx

# --- Hook de renovación: recarga servicios que usan el certificado ---
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/recargar-correo.sh <<'EOF'
#!/usr/bin/env bash
# Recarga servicios tras renovar el certificado (instalado por 60-nginx-tls.sh)
systemctl reload postfix dovecot nginx 2>/dev/null || systemctl reload postfix nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/recargar-correo.sh

log_info "Verificación de esta fase"
curl -sk -o /dev/null -w '  [%{http_code}] https://%{url_effective}\n' "https://${FQDN_HOST}" || true
CERT_FIN=$(openssl x509 -enddate -noout -in "${LIVE_DIR}/fullchain.pem" 2>/dev/null | cut -d= -f2)
echo "  [INFO] Certificado válido hasta: ${CERT_FIN:-?}"
ss -ltn | grep -q ':443 ' && echo "  [OK] 443 a la escucha" || echo "  [FALLO] 443 no escucha"

log_info "FASE WEB/TLS COMPLETADA. Siguiente: scripts/70-firewall.sh"

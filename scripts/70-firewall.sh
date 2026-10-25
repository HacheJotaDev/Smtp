#!/usr/bin/env bash
# =====================================================================
# 70-firewall.sh — ufw con superficie mínima: 22 (idealmente solo desde
# IPS_ADMIN_UFW), 25, 80, 443. Todo lo demás denegado de entrada.
#
# ⚠️ Nota Docker: los puertos publicados por Docker saltan ufw; por eso
# Mautic solo publica en 127.0.0.1:8080 (compose.yaml). No cambies eso.
# Idempotente, con confirmación explícita (riesgo de bloquear tu SSH).
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env

echo "Reglas que se aplicarán:"
echo "  - Política por defecto: DENY entrada / ALLOW salida"
if [ -n "${IPS_ADMIN_UFW:-}" ] && [ "$IPS_ADMIN_UFW" != "__RELLENAR__" ]; then
    echo "  - 22/tcp SOLO desde: $IPS_ADMIN_UFW"
else
    echo "  - 22/tcp desde cualquier origen (no definiste IPS_ADMIN_UFW: menos seguro)"
fi
echo "  - 25/tcp, 80/tcp, 443/tcp desde cualquier origen"
echo "  - El resto: denegado. Dovecot/143 y MySQL/3306 NO se abren (solo internos)"
confirmar "¿Aplicar el firewall? (asegúrate de tener otra sesión SSH abierta por si acaso)"

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

if [ -n "${IPS_ADMIN_UFW:-}" ] && [ "$IPS_ADMIN_UFW" != "__RELLENAR__" ]; then
    for ip in $IPS_ADMIN_UFW; do
        ufw allow proto tcp from "$ip" to any port 22 comment 'SSH admin' >/dev/null
    done
else
    ufw allow 22/tcp comment 'SSH admin (sin restricción de origen)' >/dev/null
fi

ufw allow 25/tcp  comment 'SMTP (DSN/rebotes entrantes)' >/dev/null
ufw allow 80/tcp  comment 'HTTP (ACME + redirección)'    >/dev/null
ufw allow 443/tcp comment 'HTTPS panel Mautic'           >/dev/null

ufw --force enable
ufw status verbose | sed 's/^/  /'

log_info "Comprobación"
ufw status | grep -q "Status: active" && echo "  [OK] ufw activo" || die "ufw no quedó activo"

log_info "FASE FIREWALL COMPLETADA. Siguiente: publicar DNS (dns/registros-dns.plantilla.md) y luego scripts/80-verificar.sh"

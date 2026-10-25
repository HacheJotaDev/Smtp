#!/usr/bin/env bash
# =====================================================================
# 30-dkim.sh — genera la clave DKIM 2048 (si no existe) y configura
# OpenDKIM. NUNCA sobrescribe una clave existente y NUNCA imprime la
# privada. Idempotente.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env
validar_vars DOMINIO SELECTOR_DKIM
sin_marcadores "$ARCHIVO_ENV"

DIR_CLAVES="/etc/opendkim/claves/${DOMINIO}"
CLAVE_PRIVADA="${DIR_CLAVES}/${SELECTOR_DKIM}.private"

echo "Acciones que realizará este script:"
echo "  - Directorio de claves: $DIR_CLAVES (permisos restringidos)"
if [ -f "$CLAVE_PRIVADA" ]; then
    echo "  - La clave ya existe: NO se regenerará (protección anti-pérdida)"
else
    echo "  - Generar clave DKIM 2048 bits (opendkim-genkey)"
fi
echo "  - Renderizar /etc/opendkim.conf + tablas (respaldo previo)"
echo "  - Arrancar OpenDKIM y comprobar socket 127.0.0.1:8891"
confirmar "¿Continuar?"

# --- Clave (solo si no existe) ---
install -d -m 750 -o opendkim -g opendkim "$DIR_CLAVES"
if [ -f "$CLAVE_PRIVADA" ]; then
    log_info "Clave existente conservada: $CLAVE_PRIVADA"
else
    opendkim-genkey -b 2048 -d "$DOMINIO" -s "$SELECTOR_DKIM" -D "$DIR_CLAVES" -v
    chown opendkim:opendkim "$CLAVE_PRIVADA" "${DIR_CLAVES}/${SELECTOR_DKIM}.txt"
    chmod 600 "$CLAVE_PRIVADA"
    chmod 644 "${DIR_CLAVES}/${SELECTOR_DKIM}.txt"
    log_info "Clave DKIM generada. La PRIVADA tiene permisos 600 y NUNCA se commitea."
fi

# --- Configuración y tablas ---
bash "$DIR_SCRIPTS/renderizar-plantillas.sh" dkim

chown -R opendkim:opendkim /etc/opendkim
chmod 640 /etc/opendkim/Tabla* 2>/dev/null || true
chmod 750 /etc/opendkim/claves 2>/dev/null || true
chmod 750 "$DIR_CLAVES"

# --- Servicio ---
systemctl enable opendkim >/dev/null 2>&1 || true
systemctl restart opendkim

sleep 2
systemctl is-active --quiet opendkim && echo "  [OK] opendkim activo" || die "opendkim no arrancó: journalctl -u opendkim -e"
ss -ltn | grep -q '127.0.0.1:8891' && echo "  [OK] milter a la escucha en 127.0.0.1:8891" || die "OpenDKIM no escucha en 127.0.0.1:8891"

# --- Prueba DNS informativa (fallará hasta publicar el TXT; es esperado) ---
log_info "opendkim-testkey (informativo: fallará hasta publicar el registro TXT de DKIM)"
opendkim-testkey -d "$DOMINIO" -s "$SELECTOR_DKIM" -vvv 2>&1 | sed 's/^/  /' || true

echo
log_info "Para obtener el registro TXT a publicar (clave PÚBLICA):"
echo "  cat ${DIR_CLAVES}/${SELECTOR_DKIM}.txt"
echo "  o ejecuta: scripts/mostrar-dns.sh"
log_info "FASE DKIM COMPLETADA. Siguiente: scripts/40-dovecot.sh"

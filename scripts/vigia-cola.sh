#!/usr/bin/env bash
# =====================================================================
# vigia-cola.sh — vigilante operativa (cron cada 10 min, ver
# cron/crontab-mantenimiento.plantilla). Comprueba:
#   - Tamaño de la cola de Postfix (MAX_COLA)
#   - Disco (MAX_DISCO_PCT)
#   - Servicios activos y contenedores
#   - OpenDKIM a la escucha
# Ante anomalía: registra en /var/log/campanas/vigia.log y envía un
# correo de alerta a CORREO_POSTMASTER vía sendmail local (limitación
# documentada: si Postfix cae, la alerta no puede salir — mantén un
# monitor externo de uptime, ver docs/06-operacion.md).
# Tiene cooldown por tipo de alerta (1 h) para no saturar.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MAX_COLA="${MAX_COLA:-200}"
MAX_DISCO_PCT="${MAX_DISCO_PCT:-85}"
COOLDOWN_SEG="${COOLDOWN_SEG:-3600}"
DIR_ESTADO="/var/lib/campanas"
ALERTAS_ENVIADAS=0

cargar_env_opcional "$ARCHIVO_ENV" || true
DESTINATARIO="${CORREO_POSTMASTER:-}"

install -d -m 755 "$DIR_ESTADO" /var/log/campanas

alertar() {
    local clave="$1" mensaje="$2"
    local ahora hora_ultimo
    ahora=$(date +%s)
    hora_ultimo=$(cat "${DIR_ESTADO}/alerta-${clave}" 2>/dev/null || echo 0)
    if [ $((ahora - hora_ultimo)) -lt "$COOLDOWN_SEG" ]; then
        return 0
    fi
    echo "$ahora" > "${DIR_ESTADO}/alerta-${clave}"
    echo "[$(date '+%F %T')] ALERTA [$clave] $mensaje" >> /var/log/campanas/vigia.log
    if [ -n "$DESTINATARIO" ] && [ -x /usr/sbin/sendmail ]; then
        printf 'To: %s\nSubject: [ALERTA campanas] %s\n\n%s\nServidor: %s\nFecha: %s\n' \
            "$DESTINATARIO" "$clave" "$mensaje" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%F %T')" \
            | /usr/sbin/sendmail -t || true
        ALERTAS_ENVIADAS=$((ALERTAS_ENVIADAS+1))
    fi
}

# --- Cola de Postfix ---
if command -v postqueue >/dev/null 2>&1; then
    COLA=$(postqueue -p 2>/dev/null | grep -c '^[A-F0-9]' || true)
    if [ "$COLA" -gt "$MAX_COLA" ]; then
        MUESTRA=$(postqueue -p 2>/dev/null | tail -15 || true)
        alertar "cola-alta" "Cola de Postfix: $COLA mensajes (> $MAX_COLA).
Posibles causas: receptor lento, rebotes masivos, bloqueo externo. Últimos elementos:
$MUESTRA"
    else
        echo "[$(date '+%F %T')] cola OK ($COLA)" >> /var/log/campanas/vigia.log
    fi
fi

# --- Disco ---
DISCO=$(df -BG / | awk 'NR==2{gsub("G","",$5); print $5}')
if [ "${DISCO:-0}" -ge "$MAX_DISCO_PCT" ]; then
    alertar "disco" "Disco de / al ${DISCO}% (umbral ${MAX_DISCO_PCT}%). Revisa logs y backups antiguos."
fi

# --- Servicios ---
for s in postfix opendkim dovecot; do
    systemctl is-active --quiet "$s" || alertar "servicio-$s" "El servicio $s está CAÍDO: systemctl status $s; journalctl -u $s -e"
done
if command -v docker >/dev/null 2>&1 && [ -f "$DIR_REPO/compose.yaml" ]; then
    if ! (cd "$DIR_REPO" && docker compose ps 2>/dev/null | grep -q mautic_web); then
        alertar "mautic" "El contenedor mautic_web no está corriendo: docker compose -f $DIR_REPO/compose.yaml ps"
    fi
fi

# --- Milter DKIM ---
if ! ss -ltn 2>/dev/null | grep -q '127.0.0.1:8891'; then
    alertar "opendkim-milter" "OpenDKIM no escucha en 127.0.0.1:8891. Con milter_default_action=tempfail el envío saliente quedará RETRASADO."
fi

exit 0

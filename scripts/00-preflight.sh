#!/usr/bin/env bash
# =====================================================================
# 00-preflight.sh — comprobaciones PREVIAS al despliegue (solo lectura:
# no modifica nada del sistema). Detecta condiciones que deben
# resolverse ANTES de instalar: SO, recursos, puertos, DNS, PTR y
# bloqueo del puerto 25 por el proveedor.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log_info "=== PREFLIGHT: comprobaciones previas (no se modifica nada) ==="

FALLOS=0
avisos=0

ok()   { echo "  [OK]    $*"; }
fallo(){ echo "  [FALLO] $*"; FALLOS=$((FALLOS+1)); }
aviso(){ echo "  [AVISO] $*"; avisos=$((avisos+1)); }

# --- SO y entorno ---
echo "-- Sistema operativo --"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}-${VERSION_ID:-}" = "ubuntu-24.04" ]; then
        ok "SO soportado: ${PRETTY_NAME}"
    else
        fallo "SO ${PRETTY_NAME:-?} != Ubuntu 24.04 LTS. El despliegue se detendrá."
    fi
else
    fallo "/etc/os-release no disponible"
fi
[ "$(id -u)" -eq 0 ] && ok "Ejecución como root" || aviso "No eres root: los scripts de instalación lo exigirán"

echo "-- Recursos --"
RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
if [ "${RAM_MB:-0}" -ge 1800 ]; then ok "RAM: ${RAM_MB} MB"; else fallo "RAM insuficiente: ${RAM_MB} MB (mínimo 1800)"; fi
DISCO_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
if [ "${DISCO_GB:-0}" -ge 8 ]; then ok "Disco libre en /: ${DISCO_GB} GB"; else fallo "Disco libre insuficiente: ${DISCO_GB} GB"; fi
if command -v systemd-detect-virt >/dev/null; then
    VIRT=$(systemd-detect-virt || true)
    ok "Virtualización: ${VIRT:-desconocida}"
fi
if swapon --show >/dev/null 2>&1 && [ -n "$(swapon --show 2>/dev/null)" ]; then
    ok "Swap activa"
else
    aviso "Sin swap: con 2 GB de RAM es recomendable añadir 2 GB de swap"
fi

echo "-- Reloj --"
if command -v timedatectl >/dev/null; then
    if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
        ok "Reloj sincronizado (NTP)"
    else
        aviso "Reloj sin sincronizar: ejecuta 'timedatectl set-ntp true'"
    fi
fi

echo "-- Puertos locales --"
for p in 25 80 443 587 143 3306; do
    if ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
        PROC=$(ss -ltnp "sport = :$p" 2>/dev/null | tail -1 | sed 's/.*users:((\("[^"]*"\).*/\1/' || true)
        aviso "Puerto $p ya ocupado: ${PROC:-servicio desconocido} (revisar antes de instalar)"
    else
        ok "Puerto $p libre"
    fi
done

echo "-- Paquetes previos conflictivos --"
for p in exim4 sendmail mautic; do
    if dpkg -s "$p" >/dev/null 2>&1; then aviso "Paquete $p ya instalado (posible conflicto de MTA)"; fi
done
if dpkg -s postfix >/dev/null 2>&1; then aviso "Postfix ya instalado: los scripts son idempotentes, pero revisa su configuración actual"; else ok "Postfix no instalado todavía (instalación limpia)"; fi

# --- Variables de configuración ---
echo "-- correo.env --"
if [ -f "$ARCHIVO_ENV" ]; then
    cargar_env
    if grep -q "__RELLENAR" "$ARCHIVO_ENV"; then
        aviso "correo.env aún tiene valores __RELLENAR__ sin rellenar"
    else
        ok "correo.env cargado (dominio: ${DOMINIO:-?}, host: ${FQDN_HOST:-?})"
        ENV_OK=1
    fi
else
    aviso "No existe correo.env (cópialo desde correo.env.example); se omiten las comprobaciones de red externa"
    ENV_OK=0
fi

# --- Red externa (solo con correo.env rellenado) ---
if [ "${ENV_OK:-0}" = "1" ]; then
    echo "-- IP pública y NAT --"
    IP_LOCAL=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    IP_PUBLICA=$(timeout 10 curl -4 -fsS https://api.ipify.org 2>/dev/null || true)
    if [ -n "$IP_PUBLICA" ]; then
        if [ "$IP_PUBLICA" = "$IP_SERVIDOR" ]; then
            ok "IP pública declarada coincide con la detectada: $IP_PUBLICA"
        else
            aviso "IP pública detectada ($IP_PUBLICA) != IP_SERVIDOR declarada ($IP_SERVIDOR). ¿NAT? El correo necesita IP dedicada con PTR propio."
        fi
        if [ -n "$IP_LOCAL" ] && [ "$IP_LOCAL" != "$IP_PUBLICA" ]; then
            aviso "La IP del interfaz ($IP_LOCAL) no es la pública ($IP_PUBLICA): posible NAT/proxy del proveedor"
        fi
    else
        aviso "No se pudo consultar la IP pública (sin Internet o servicio caído)"
    fi

    echo "-- DNS directo/inverso --"
    if command -v dig >/dev/null 2>&1; then
        A_RES=$(dig +short A "$FQDN_HOST" @1.1.1.1 2>/dev/null | tail -1)
        [ "$A_RES" = "$IP_SERVIDOR" ] && ok "A $FQDN_HOST -> $IP_SERVIDOR" || aviso "A $FQDN_HOST resuelve '$A_RES' (esperado: $IP_SERVIDOR). Publica/propaga el registro."
        PTR_RES=$(dig +short -x "$IP_SERVIDOR" @1.1.1.1 2>/dev/null | head -1 | sed 's/\.$//')
        [ "$PTR_RES" = "$FQDN_HOST" ] && ok "PTR $IP_SERVIDOR -> $FQDN_HOST" || aviso "PTR actual: '$PTR_RES' (esperado: $FQDN_HOST). Configúralo en el panel del proveedor."
    else
        aviso "dig no disponible (se instalará con el resto de paquetes)"
    fi

    echo "-- Puerto 25 saliente (bloqueo de proveedor) --"
    if timeout 10 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
        ok "Conexión saliente al puerto 25 establecida (no parece bloqueado)"
    else
        fallo "NO se pudo conectar saliente al puerto 25. Posible bloqueo del proveedor.
         → Si el proveedor confirma el bloqueo: DETÉN el plan de envío directo.
         → No se usará ninguna API externa como sustituto (decisión de arquitectura)."
    fi
fi

echo
echo "================ RESUMEN PREFLIGHT ================"
echo "  Fallos: $FALLOS   Avisos: $avisos"
if [ "$FALLOS" -gt 0 ]; then
    log_err "Resuelve los fallos antes de continuar con la instalación."
    exit 1
fi
log_info "Preflight completado. Revisa los AVISOS y continúa con scripts/10-base.sh"

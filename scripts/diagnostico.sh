#!/usr/bin/env bash
# =====================================================================
# diagnostico.sh — recopila un informe de diagnóstico consolidado para
# resolver incidencias o enviarlo a soporte/informe interno.
# SOLO LECTURA. Uso: scripts/diagnostico.sh [--fichero]
#   --fichero: además de en pantalla, guarda diagnostico-<fecha>.txt
#   (evita pegar secretos: no se muestran claves ni .env)
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

GUARDAR=0
[ "${1:-}" = "--fichero" ] && GUARDAR=1

cargar_env_opcional "$ARCHIVO_ENV" || true

INFORME=$(mktemp /tmp/diagnostico-XXXXXX.txt)

seccion() { echo; echo "############ $* ############" | tee -a "$INFORME"; }
ejec()    { echo "\$ $*" | tee -a "$INFORME";
    # shellcheck disable=SC2294
    eval "$@" 2>&1 | tee -a "$INFORME"; }

{
echo "INFORME DE DIAGNÓSTICO — $(date '+%F %T')"
echo "Host: $(hostname -f 2>/dev/null || hostname)  Kernel: $(uname -r)"
echo "AVISO: no incluir este informe en sitios públicos sin revisarlo."
} > "$INFORME"

seccion "Sistema"
ejec "uname -a"
ejec "grep PRETTY_NAME /etc/os-release"
ejec "uptime"

seccion "Servicios"
ejec "systemctl is-active postfix opendkim dovecot nginx docker 2>&1 || true"

seccion "Postfix (configuración efectiva, sin valores sensibles)"
ejec "postconf -n 2>/dev/null || true"

seccion "Cola de Postfix"
ejec "postqueue -p 2>/dev/null | tail -20 || true"

seccion "OpenDKIM"
ejec "systemctl status opendkim --no-pager -l 2>&1 | head -20 || true"
ejec "ss -ltnp 2>/dev/null | grep 8891 || true"

seccion "Dovecot"
ejec "doveconf -n 2>/dev/null | head -40 || true"

seccion "DNS (si correo.env está cargado)"
if [ -n "${FQDN_HOST:-}" ] && command -v dig >/dev/null 2>&1; then
    ejec "dig +short A ${FQDN_HOST}"
    ejec "dig +short -x ${IP_SERVIDOR:-}"
    ejec "dig +short MX ${DOMINIO:-}"
    ejec "dig +short TXT ${DOMINIO:-}"
    ejec "dig +short TXT ${SELECTOR_DKIM:-mta1}._domainkey.${DOMINIO:-}"
    ejec "dig +short TXT _dmarc.${DOMINIO:-}"
fi

seccion "Últimas líneas del log de correo"
ejec "tail -40 /var/log/mail.log 2>/dev/null || journalctl -u postfix -n 40 --no-pager 2>/dev/null || true"

seccion "Errores recientes"
ejec "tail -20 /var/log/mail.err 2>/dev/null || true"

seccion "Docker / Mautic"
if command -v docker >/dev/null 2>&1 && [ -f "$DIR_REPO/compose.yaml" ]; then
    (cd "$DIR_REPO" && ejec "docker compose ps" && ejec "docker compose logs --tail=30 mautic_web")
fi

seccion "Recursos"
ejec "df -h /"
ejec "free -m"

seccion "Firewall"
ejec "ufw status verbose 2>/dev/null || true"

echo
if [ "$GUARDAR" = "1" ]; then
    DESTINO="${DIR_REPO}/diagnostico-$(marca_fecha).txt"
    cp "$INFORME" "$DESTINO"
    chmod 600 "$DESTINO"
    echo "Informe guardado en: $DESTINO"
    echo "(está en .gitignore el patrón diagnostico-*.txt; NO lo commits sin revisarlo)"
else
    cat "$INFORME"
fi
rm -f "$INFORME"

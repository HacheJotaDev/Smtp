#!/usr/bin/env bash
# =====================================================================
# 80-verificar.sh — verificación post-instalación y operativa.
# Comprueba servicios, anti-relay (prueba ACTIVA), TLS, DNS/SPF/DKIM/
# DMARC/PTR, firewall, recursos y cola. El envío de prueba solo se
# ejecuta con --enviar-prueba y confirmación explícita.
# Sin argumentos: modo de comprobación de solo lectura.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENVIO_PRUEBA=0
[ "${1:-}" = "--enviar-prueba" ] && ENVIO_PRUEBA=1

FALLOS=0
ok()    { echo "  [OK]    $*"; }
fallo() { echo "  [FALLO] $*"; FALLOS=$((FALLOS+1)); }
aviso() { echo "  [AVISO] $*"; }
seccion(){ echo; echo "== $* =="; }

cargar_env_opcional "$ARCHIVO_ENV" || true
CON_ENV=1
cargar_env 2>/dev/null || CON_ENV=0

# ---------------------------------------------------------------------
seccion "1. Servicios activos"
for s in postfix opendkim dovecot nginx rsyslog docker; do
    if systemctl is-active --quiet "$s"; then ok "$s activo"; else fallo "$s NO activo (systemctl status $s)"; fi
done
if command -v docker >/dev/null 2>&1 && [ -f "$DIR_REPO/compose.yaml" ]; then
    cd "$DIR_REPO" || die "No se pudo acceder a $DIR_REPO"
    if docker compose ps 2>/dev/null | grep -q mautic_web; then
        ok "contenedor mautic_web presente"
        docker compose ps --format '{{.Name}} {{.Status}}' | sed 's/^/    /'
    else
        fallo "contenedor mautic_web no está corriendo (docker compose -f $DIR_REPO/compose.yaml ps)"
    fi
else
    aviso "Docker o compose.yaml no disponibles todavía (ejecuta 50-mautic.sh)"
fi

# ---------------------------------------------------------------------
seccion "2. Configuración Postfix (sin open relay)"
if command -v postconf >/dev/null 2>&1; then
    relay_conf=$(postconf -h smtpd_relay_restrictions 2>/dev/null | tr '\n' ' ')
    case "$relay_conf" in
        *reject_unauth_destination*) ok "reject_unauth_destination presente" ;;
        *) fallo "smtpd_relay_restrictions SIN reject_unauth_destination" ;;
    esac
    mynets=$(postconf -h mynetworks 2>/dev/null)
    case "$mynets" in
        *0.0.0.0/0*|*::/0*) fallo "mynetworks demasiado amplio: $mynets" ;;
        *) ok "mynetworks = $mynets" ;;
    esac
    postconf -h inet_interfaces | grep -q all && ok "inet_interfaces = all (necesario para recibir DSN)" || aviso "inet_interfaces: $(postconf -h inet_interfaces)"
    postconf -h myhostname
else
    fallo "postconf no disponible"
fi

# --- Prueba ACTIVA de open relay (contra nosotros mismos) ---
seccion "3. Prueba activa de open relay (127.0.0.1:25)"
if command -v postconf >/dev/null 2>&1; then
    PROBE_EXT="probe-relay@dominio-externo-invalid.example"
    RESP=$( (exec 3<>/dev/tcp/127.0.0.1/25 && \
        printf 'EHLO probe.local\r\n' >&3 && sleep 0.3 && \
        printf 'MAIL FROM:<relay-test@dominio-externo-invalid.example>\r\n' >&3 && sleep 0.3 && \
        printf 'RCPT TO:<%s>\r\n' "$PROBE_EXT" >&3 && sleep 0.5 && \
        timeout 2 head -n 40 <&3) 2>/dev/null | tr -d '\r' ) || RESP=""
    if echo "$RESP" | grep -Eq '^55[0-9]'; then
        ok "Relay rechazado como debe: $(echo "$RESP" | grep -E '^55' | head -1)"
    elif echo "$RESP" | grep -Eq '^250'; then
        fallo "¡El servidor ACEPTÓ retransmitir a un destino externo sin autenticar!"
    else
        aviso "No se obtuvo respuesta clara para la prueba de relay (¿iptables/ufw?, revisa manualmente con: nc 127.0.0.1 25)"
    fi
else
    aviso "Sin postfix instalado aún: prueba omitida"
fi

# ---------------------------------------------------------------------
seccion "4. TLS"
if command -v openssl >/dev/null 2>&1 && [ -n "${FQDN_HOST:-}" ]; then
    if timeout 8 bash -c "echo | openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername ${FQDN_HOST} 2>/dev/null | grep -q 'Protocol'"; then
        ok "STARTTLS disponible en el puerto 25"
        timeout 8 openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername "$FQDN_HOST" </dev/null 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | sed 's/^/    /'
    else
        aviso "STARTTLS no verificable en 25 (¿certificado aún no emitido? ejecuta 60-nginx-tls.sh)"
    fi
    if [ -f "/etc/letsencrypt/live/${FQDN_HOST}/fullchain.pem" ]; then
        openssl x509 -noout -checkend 604800 -in "/etc/letsencrypt/live/${FQDN_HOST}/fullchain.pem" \
            && ok "Certificado HTTPS válido >7 días" || aviso "Certificado caduca en menos de 7 días (revisa renovación)"
    fi
fi

# ---------------------------------------------------------------------
seccion "5. DNS: A/PTR/MX/SPF/DKIM/DMARC"
if [ "$CON_ENV" = "1" ] && command -v dig >/dev/null 2>&1; then
    A_RES=$(dig +short A "$FQDN_HOST" @1.1.1.1 2>/dev/null | tail -1)
    [ "$A_RES" = "$IP_SERVIDOR" ] && ok "A $FQDN_HOST -> $IP_SERVIDOR" || aviso "A: '$A_RES' (esperado $IP_SERVIDOR)"
    PTR_RES=$(dig +short -x "$IP_SERVIDOR" @1.1.1.1 2>/dev/null | head -1 | sed 's/\.$//')
    [ "$PTR_RES" = "$FQDN_HOST" ] && ok "PTR $IP_SERVIDOR -> $FQDN_HOST" || aviso "PTR: '$PTR_RES' (esperado $FQDN_HOST)"
    MX_RES=$(dig +short MX "$DOMINIO" @1.1.1.1 2>/dev/null | head -1)
    echo "$MX_RES" | grep -q "$FQDN_HOST" && ok "MX $DOMINIO -> $FQDN_HOST" || aviso "MX: '$MX_RES'"
    SPF_RES=$(dig +short TXT "$DOMINIO" @1.1.1.1 2>/dev/null | tr -d '"' | grep '^v=spf1' | head -1)
    if [ -n "$SPF_RES" ]; then
        echo "$SPF_RES" | grep -q "ip4:${IP_SERVIDOR}" && ok "SPF contiene ip4:$IP_SERVIDOR" || aviso "SPF no contiene la IP: $SPF_RES"
        echo "$SPF_RES" | grep -q -- '-all' && ok "SPF termina en -all" || aviso "SPF no termina en -all: $SPF_RES"
    else
        aviso "SPF no publicado aún"
    fi
    DKIM_RES=$(dig +short TXT "${SELECTOR_DKIM}._domainkey.${DOMINIO}" @1.1.1.1 2>/dev/null | tr -d '"' | tr -d ' ' | grep -o 'p=[A-Za-z0-9+/]\{20,\}' | head -1)
    [ -n "$DKIM_RES" ] && ok "DKIM público publicado (selector $SELECTOR_DKIM)" || aviso "DKIM TXT no publicado aún para selector $SELECTOR_DKIM"
    DMARC_RES=$(dig +short TXT "_dmarc.${DOMINIO}" @1.1.1.1 2>/dev/null | tr -d '"' | grep '^v=DMARC1' | head -1)
    [ -n "$DMARC_RES" ] && ok "DMARC publicado: $DMARC_RES" || aviso "DMARC no publicado aún"
    if command -v opendkim-testkey >/dev/null 2>&1 && [ -f "/etc/opendkim/claves/${DOMINIO}/${SELECTOR_DKIM}.private" ]; then
        if opendkim-testkey -d "$DOMINIO" -s "$SELECTOR_DKIM" -vvv >/dev/null 2>&1; then
            ok "opendkim-testkey: clave y DNS consistentes"
        else
            aviso "opendkim-testkey falla (normal hasta publicar el TXT DKIM)"
        fi
    fi
else
    aviso "Comprobaciones DNS omitidas (falta correo.env o dig)"
fi

# ---------------------------------------------------------------------
seccion "6. Exposición interna correcta (Dovecot/MySQL)"
if command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|::):143$'; then
        fallo "Dovecot escuchando en todas las interfaces: debe ser solo 127.0.0.1 y GW_DOCKER"
    else
        ok "IMAP 143 sin exposición pública (o aún no activo)"
    fi
    if ss -ltn | awk '{print $4}' | grep -qE '(^|:)(0\.0\.0\.0|::):3306$'; then
        fallo "MySQL/3306 expuesto: NO debe publicarse"
    else
        ok "MySQL sin exposición pública"
    fi
    ss -ltn | grep -q '127.0.0.1:8080' && ok "Mautic publicado solo en 127.0.0.1:8080" || aviso "Mautic no responde en 127.0.0.1:8080 (¿50-mautic.sh?)"
fi

# ---------------------------------------------------------------------
seccion "7. Firewall"
if command -v ufw >/dev/null 2>&1; then
    ufw status | grep -q "Status: active" && ok "ufw activo" || aviso "ufw inactivo (ejecuta 70-firewall.sh)"
    UFW_OUT=$(ufw status 2>/dev/null)
    for p in 25/tcp 80/tcp 443/tcp; do
        echo "$UFW_OUT" | grep -q "$p" && ok "ufw permite $p" || aviso "ufw no lista $p"
    done
    echo "$UFW_OUT" | grep -qE '143/tcp.*ALLOW' && aviso "ufw permite 143: no debería (IMAP es interno)" || ok "ufw no expone 143"
else
    aviso "ufw no instalado aún"
fi

# ---------------------------------------------------------------------
seccion "8. Recursos y cola"
DISCO=$(df -BG / | awk 'NR==2{gsub("G","",$5); print $5}')
[ "${DISCO:-100}" -lt 85 ] && ok "Uso de disco en /: ${DISCO}%" || aviso "Disco al ${DISCO}%: liberar espacio"
RAM_USADA=$(free -m | awk 'NR==2{printf "%d/%dMB", $3, $2}')
echo "  [INFO] RAM usada: $RAM_USADA"
if command -v postqueue >/dev/null 2>&1; then
    COLA=$(postqueue -p 2>/dev/null | grep -c '^[A-F0-9]' || true)
    echo "  [INFO] Mensajes en cola de Postfix: $COLA"
    [ "$COLA" -le 50 ] && ok "Cola dentro de lo esperado" || aviso "Cola alta ($COLA): revisa postqueue -p | tail -30"
fi

# ---------------------------------------------------------------------
seccion "9. Envío de prueba (opcional)"
if [ "$ENVIO_PRUEBA" = "1" ]; then
    confirmar "Se enviará UN mensaje de prueba local via swaks a $CORREO_POSTMASTER (pasa por DKIM). ¿Continuar?"
    if command -v swaks >/dev/null 2>&1 && [ "$CON_ENV" = "1" ]; then
        swaks --server 127.0.0.1 --from "prueba@${DOMINIO}" --to "$CORREO_POSTMASTER" \
              --header "Subject: [prueba] Cadena completa $(date +%F-%T)" \
              --body "Mensaje de prueba del servidor de campañas. Revisa DKIM/SPF en las cabeceras." \
            | tail -15
        echo "  [INFO] Verifica en el buzón destino la cabecera Authentication-Results"
        echo "         (debe incluir spf=pass y dkim=pass cuando el DNS esté publicado)."
    else
        aviso "swaks o correo.env no disponibles"
    fi
else
    echo "  [INFO] Modo solo-lectura. Para enviar UNA prueba controlada:"
    echo "         scripts/80-verificar.sh --enviar-prueba"
    echo "  Prueba de REBOTE (manual): envía con un destinatario inexistente de un"
    echo "  dominio externo controlado y verifica que el DSN llega al buzón de"
    echo "  ${DIRECCION_REBOTES:-devolucion}@${DOMINIO:-...} y Mautic lo procesa."
fi

# ---------------------------------------------------------------------
echo
echo "================= RESUMEN VERIFICACIÓN ================="
if [ "$FALLOS" -eq 0 ]; then
    log_info "Sin fallos: $FQDN_HOST pasa las comprobaciones automáticas."
else
    log_err "Hay $FALLOS fallo(s). Corrígelos antes de enviar campañas reales."
    exit 1
fi

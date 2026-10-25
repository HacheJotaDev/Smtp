#!/usr/bin/env bash
# =====================================================================
# 20-postfix.sh — configura Postfix desde las plantillas: usuario de
# rebotes, aliases, límites y restricciones anti open-relay.
# Idempotente y con autocomprobación (falla si el resultado no es seguro).
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env
validar_vars DOMINIO FQDN_HOST USUARIO_REBOTES DIRECCION_REBOTES CORREO_POSTMASTER
sin_marcadores "$ARCHIVO_ENV"

echo "Acciones que realizará este script:"
echo "  - Crear usuario local '$USUARIO_REBOTES' (buzón de rebotes, sin login)"
echo "  - Renderizar /etc/postfix/main.cf, master.cf y /etc/aliases (con respaldo previo)"
echo "  - Rotación de logs (/etc/logrotate.d/postfix-correo)"
echo "  - postfix check + arranque/enable del servicio"
confirmar "¿Continuar?"

# --- Usuario de rebotes (idempotente) ---
if id "$USUARIO_REBOTES" >/dev/null 2>&1; then
    log_info "Usuario $USUARIO_REBOTES ya existe"
else
    useradd -m -s /usr/sbin/nologin "$USUARIO_REBOTES"
    log_info "Usuario $USUARIO_REBOTES creado (shell nologin)"
fi
chmod 700 "/home/$USUARIO_REBOTES" 2>/dev/null || true

# --- Render de plantillas hacia /etc ---
bash "$DIR_SCRIPTS/renderizar-plantillas.sh" postfix

# --- mailname ---
respaldar_archivo /etc/mailname
echo "$DOMINIO" > /etc/mailname

# --- newaliases ---
newaliases

# --- logrotate ---
respaldar_archivo /etc/logrotate.d/postfix-correo
install -m 644 "$DIR_REPO/postfix/logrotate-postfix" /etc/logrotate.d/postfix-correo

# --- Autocomprobaciones de seguridad ANTES de arrancar ---
log_info "postfix check (validación de configuración)"
if ! postfix check; then
    die "postfix check detectó errores: revisa la salida anterior."
fi

log_info "Verificación de restricciones anti open-relay"
relay_conf=$(postconf -h smtpd_relay_restrictions | tr '\n' ' ')
case "$relay_conf" in
    *reject_unauth_destination*) echo "  [OK] smtpd_relay_restrictions contiene reject_unauth_destination" ;;
    *) die "FALLO DE SEGURIDAD: smtpd_relay_restrictions no contiene reject_unauth_destination." ;;
esac
case "$relay_conf" in
    *permit_mynetworks*|*permit_sasl_authenticated*) : ;;
    *) die "FALLO: no hay permits legítimos en smtpd_relay_restrictions." ;;
esac
mynets=$(postconf -h mynetworks)
echo "  [INFO] mynetworks = $mynets"
case "$mynets" in
    *0.0.0.0/0*|*::/0*|*all*) die "FALLO DE SEGURIDAD: mynetworks demasiado amplio." ;;
esac

# --- Servicio ---
systemctl enable postfix >/dev/null 2>&1 || true
systemctl restart postfix

systemctl is-active --quiet postfix && echo "  [OK] postfix activo" || die "postfix no arrancó (revisa journalctl -u postfix -e)"

log_info "Comprobación adicional: puertos a la escucha"
ss -ltnp | grep -E ':(25|587)\b' || echo "  [AVISO] aún no hay 25/587 a la escucha (puede tardar unos segundos)"

log_info "FASE POSTFIX COMPLETADA. Siguiente: scripts/30-dkim.sh"

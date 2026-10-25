#!/usr/bin/env bash
# =====================================================================
# 40-dovecot.sh — Dovecot mínimo: IMAP interno del buzón de rebotes y
# SASL para Postfix. No expone nada a Internet (listen restringido).
# Idempotente.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env
validar_vars USUARIO_REBOTES GW_DOCKER DIRECCION_REBOTES DOMINIO
sin_marcadores "$ARCHIVO_ENV"

echo "Acciones que realizará este script:"
echo "  - Renderizar /etc/dovecot/conf.d/99-correo.conf (respaldo previo)"
echo "  - Escucha restringida a 127.0.0.1 y ${GW_DOCKER} (gateway Docker)"
echo "  - Socket SASL para Postfix (/var/spool/postfix/private/auth)"
echo "  - Comprobar que el buzón Maildir de '$USUARIO_REBOTES' existe"
confirmar "¿Continuar?"

id "$USUARIO_REBOTES" >/dev/null 2>&1 || die "El usuario $USUARIO_REBOTES no existe: ejecuta antes scripts/20-postfix.sh"

# Maildir inicial (Postfix también lo crea al primer mensaje)
MAILDIR="/home/${USUARIO_REBOTES}/Maildir"
install -d -m 700 -o "$USUARIO_REBOTES" -g "$USUARIO_REBOTES" \
    "$MAILDIR" "$MAILDIR/cur" "$MAILDIR/new" "$MAILDIR/tmp"

bash "$DIR_SCRIPTS/renderizar-plantillas.sh" dovecot

# La plantilla debe haber quedado sin marcadores y con la escucha correcta
if ! grep -q "listen = 127.0.0.1, ${GW_DOCKER}" /etc/dovecot/conf.d/99-correo.conf; then
    die "La configuración de Dovecot no quedó como se esperaba (revisa el render)."
fi

systemctl enable dovecot >/dev/null 2>&1 || true
systemctl restart dovecot

systemctl is-active --quiet dovecot && echo "  [OK] dovecot activo" || die "dovecot no arrancó: journalctl -u dovecot -e"

log_info "Validación de sintaxis (doveconf -n)"
doveconf -n > /dev/null && echo "  [OK] doveconf sin errores"

log_info "Escuchas de Dovecot (NO debe aparecer 0.0.0.0):"
ss -ltnp | grep dovecot | sed 's/^/  /' || echo "  [AVISO] sin escuchas visibles todavía"

log_info "Prueba SASL (socket en chroot de Postfix)"
[ -S /var/spool/postfix/private/auth ] && echo "  [OK] /var/spool/postfix/private/auth existe" || echo "  [AVISO] socket SASL aún no visible; se creará al rearrancar postfix"

log_info "Prueba de autenticación IMAP del usuario de rebotes (opcional):"
echo "  doveadm auth test $USUARIO_REBOTES   # pedirá la contraseña del usuario"
log_info "FASE DOVECOT COMPLETADA. Siguiente: scripts/50-mautic.sh"

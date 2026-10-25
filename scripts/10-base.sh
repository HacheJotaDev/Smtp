#!/usr/bin/env bash
# =====================================================================
# 10-base.sh — base del sistema: paquetes, logging y actualizaciones
# automáticas de seguridad. Idempotente: se puede re-ejecutar.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os
cargar_env
sin_marcadores "$ARCHIVO_ENV"

echo "Acciones que realizará este script:"
echo "  - apt update (+ upgrade si se pasa --con-upgrade)"
echo "  - Instalar: postfix opendkim opendkim-tools dovecot-core dovecot-imapd"
echo "              nginx certbot python3-certbot-nginx rsyslog ufw curl swaks dig"
echo "              unattended-upgrades"
echo "  - Configurar logging de correo y actualizaciones automáticas de seguridad"
confirmar "¿Continuar?"

export DEBIAN_FRONTEND=noninteractive

log_info "apt update"
apt-get update -qq

if [ "${1:-}" = "--con-upgrade" ]; then
    log_info "apt upgrade completo (puede tardar)"
    apt-get -y -qq upgrade
else
    log_aviso "Sin 'apt upgrade' completo (usa --con-upgrade si quieres); solo se instalan paquetes nuevos"
fi

# Evita el asistente de debconf de Postfix: la configuración la imponen
# nuestras plantillas más adelante.
echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
echo "postfix postfix/mailname string ${FQDN_HOST}" | debconf-set-selections

log_info "Instalación de paquetes (idempotente)"
PAQUETES=(postfix opendkim opendkim-tools dovecot-core dovecot-imapd
          nginx certbot python3-certbot-nginx rsyslog ufw curl
          dnsutils swaks unattended-upgrades ca-certificates)
for p in "${PAQUETES[@]}"; do
    paquete_si_falta "$p"
done

log_info "Logging de correo a /var/log/mail.log"
respaldar_archivo /etc/rsyslog.d/30-correo.conf
cat > /etc/rsyslog.d/30-correo.conf <<'EOF'
# Logging de Postfix/Dovecot/OpenDKIM (gestionado por el proyecto Smtp)
mail.*      -/var/log/mail.log
mail.err    /var/log/mail.err
& stop
EOF
systemctl enable --now rsyslog >/dev/null 2>&1 || true
systemctl restart rsyslog

log_info "Directorio de logs del proyecto"
install -d -m 750 /var/log/campanas

log_info "Actualizaciones automáticas de seguridad"
respaldar_archivo /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log_info "Comprobaciones de esta fase"
dpkg -s postfix >/dev/null 2>&1 && echo "  [OK] postfix instalado" || echo "  [FALLO] postfix"
dpkg -s opendkim >/dev/null 2>&1 && echo "  [OK] opendkim instalado" || echo "  [FALLO] opendkim"
dpkg -s dovecot-core >/dev/null 2>&1 && echo "  [OK] dovecot-core instalado" || echo "  [FALLO] dovecot-core"
command -v certbot >/dev/null && echo "  [OK] certbot" || echo "  [FALLO] certbot"
[ -f /var/log/mail.log ] && echo "  [OK] /var/log/mail.log existe" || echo "  [AVISO] /var/log/mail.log se creará con el primer evento"

log_info "FASE BASE COMPLETADA. Siguiente: scripts/20-postfix.sh"

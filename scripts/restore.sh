#!/usr/bin/env bash
# =====================================================================
# restore.sh — restauración a partir de una copia de backup.sh.
# USO: scripts/restore.sh /var/backups/campanas/backup-campanas-XXX.tar.gz
# Operación SENSIBLE: pide confirmación explícita y respalda el estado
# actual antes de sobrescribir nada.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
cargar_env_opcional "$ARCHIVO_ENV" || true

COPIA="${1:-}"
[ -n "$COPIA" ] && [ -f "$COPIA" ] || die "Uso: scripts/restore.sh /ruta/a/backup-campanas-XXXX.tar.gz(.enc)"

if [[ "$COPIA" == *.enc ]]; then
    SECRETS="/etc/campanas/secrets.env"
    [ -f "$SECRETS" ] || die "La copia está cifrada y falta $SECRETS (BACKUP_PASSPHRASE)"
    # shellcheck disable=SC1090
    set -a; . "$SECRETS"; set +a
    DESCIFRADO=$(mktemp)
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -in "$COPIA" -out "$DESCIFRADO" -pass env:BACKUP_PASSPHRASE \
        || die "No se pudo descifrar la copia (¿passphrase incorrecta?)"
    COPIA="$DESCIFRADO"
fi

echo "RESTAURACIÓN — operaciones que se realizarán:"
echo "  1. Respaldar el estado ACTUAL en /var/backups/campanas/pre-restore-<fecha>.tar.gz"
echo "  2. Extraer la copia indicada a un directorio temporal"
echo "  3. Restaurar /etc/postfix, /etc/opendkim*, Dovecot, nginx, aliases, mailname"
echo "  4. Restaurar la BD de Mautic (IMPORTando el dump SQL)"
echo "  5. Recargar servicios y verificar"
confirmar "¿Restaurar la copia $1?"

STAMP=$(marca_fecha)
DIR_TRABAJO=$(mktemp -d /tmp/restore-campanas.XXXXXX)
trap '[ -n "${DESCIFRADO:-}" ] && rm -f "$DESCIFRADO"; rm -rf "$DIR_TRABAJO"' EXIT

# 1) Respaldo del estado actual (por si hay que volver atrás)
log_info "Respaldo del estado actual antes de restaurar"
install -d -m 700 /var/backups/campanas
tar -czf "/var/backups/campanas/pre-restore-${STAMP}.tar.gz" \
    -C / etc/postfix etc/opendkim.conf etc/opendkim etc/aliases etc/mailname \
       etc/nginx/sites-available/campanas etc/dovecot/conf.d/99-correo.conf \
       2>/dev/null || log_aviso "Respaldo parcial (algunas rutas no existían)"
chmod 600 "/var/backups/campanas/pre-restore-${STAMP}.tar.gz"

# 2) Extraer
tar -xzf "$COPIA" -C "$DIR_TRABAJO" || die "No se pudo extraer la copia"
[ -d "$DIR_TRABAJO/etc" ] || die "La copia no tiene el formato esperado (falta /etc)"

# 3) Configuraciones
log_info "Restaurando configuraciones del sistema"
cp -a "$DIR_TRABAJO/etc/postfix" /etc/ 2>/dev/null || log_aviso "sin /etc/postfix en la copia"
[ -f "$DIR_TRABAJO/etc/opendkim.conf" ] && cp -a "$DIR_TRABAJO/etc/opendkim.conf" /etc/
[ -d "$DIR_TRABAJO/etc/opendkim" ] && cp -a "$DIR_TRABAJO/etc/opendkim" /etc/
[ -f "$DIR_TRABAJO/etc/dovecot-99-correo.conf" ] && cp -a "$DIR_TRABAJO/etc/dovecot-99-correo.conf" /etc/dovecot/conf.d/99-correo.conf
[ -f "$DIR_TRABAJO/etc/nginx-campanas.conf" ] && cp -a "$DIR_TRABAJO/etc/nginx-campanas.conf" /etc/nginx/sites-available/campanas
[ -f "$DIR_TRABAJO/etc/aliases" ] && cp -a "$DIR_TRABAJO/etc/aliases" /etc/aliases
[ -f "$DIR_TRABAJO/etc/mailname" ] && cp -a "$DIR_TRABAJO/etc/mailname" /etc/mailname
[ -f "$DIR_TRABAJO/etc/correo.env" ] && cp -a "$DIR_TRABAJO/etc/correo.env" "$ARCHIVO_ENV"
[ -f "$DIR_TRABAJO/etc/compose.env" ] && cp -a "$DIR_TRABAJO/etc/compose.env" "$DIR_REPO/.env"
chmod 600 "$DIR_REPO/.env" 2>/dev/null || true

# Permisos críticos de claves DKIM restauradas
find /etc/opendkim/claves -name '*.private' -exec chown opendkim:opendkim {} \; 2>/dev/null || true
find /etc/opendkim/claves -name '*.private' -exec chmod 600 {} \; 2>/dev/null || true

newaliases 2>/dev/null || true
postfix check || die "postfix check falló tras restaurar configs"
systemctl reload postfix dovecot nginx 2>/dev/null || systemctl restart postfix dovecot nginx

# 4) Base de datos
SQL="$DIR_TRABAJO/mautic-db.sql.gz"
if [ -f "$SQL" ]; then
    log_info "Restaurando base de datos de Mautic"
    cd "$DIR_REPO" || die "No se pudo acceder a $DIR_REPO"
    docker compose up -d db
    for _ in $(seq 1 24); do
        [ "$(docker compose ps --format '{{.Health}}' db 2>/dev/null)" = "healthy" ] && break
        sleep 5
    done
    gunzip -c "$SQL" | docker compose exec -T db sh -c \
        'exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' \
        || die "Fallo importando la BD"
    docker compose up -d
else
    log_aviso "La copia no contiene dump de BD: se restauran solo configuraciones"
fi

log_info "Verificación rápida"
bash "$DIR_SCRIPTS/80-verificar.sh" || true
log_info "RESTAURACIÓN COMPLETADA. Verifica el panel de Mautic y un envío de prueba antes de reanudar campañas."

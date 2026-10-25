#!/usr/bin/env bash
# =====================================================================
# backup.sh — copia de seguridad de:
#   - Base de datos de Mautic (mysqldump transaccional vía docker)
#   - Configuraciones: /etc/postfix, /etc/opendkim.conf, /etc/opendkim
#     (incluye CLAVE PRIVADA DKIM), /etc/dovecot/conf.d/99-correo.conf,
#     /etc/nginx/sites-available/campanas, /etc/aliases, /etc/mailname
#   - correo.env y .env del repositorio (contienen secretos: permisos 600)
# Opcional --cifrar: cifra el tar con la clave de /etc/campanas/secrets.env
#   (BACKUP_PASSPHRASE=...). Recomendado para copias fuera del servidor.
# Retención: conserva las RETENCION_COPIAS más recientes (7 por defecto).
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
cargar_env_opcional "$ARCHIVO_ENV" || true

DESTINO="${DESTINO_COPIAS:-/var/backups/campanas}"
RETENCION="${RETENCION_COPIAS:-7}"
STAMP=$(marca_fecha)
DIR_TRABAJO=$(mktemp -d /tmp/backup-campanas.XXXXXX)
trap 'rm -rf "$DIR_TRABAJO"' EXIT

install -d -m 700 "$DESTINO"

log_info "Volcado de base de datos Mautic"
cd "$DIR_REPO" || die "No se pudo acceder a $DIR_REPO"
if docker compose ps 2>/dev/null | grep -q db; then
    # Credenciales leídas DENTRO del contenedor (no aparecen en el host ni en logs)
    docker compose exec -T db sh -c \
        'exec mysqldump --single-transaction --quick --routines -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' \
        > "${DIR_TRABAJO}/mautic-db.sql" \
        || die "mysqldump falló: backup ABORTADO (no se pierden datos; revisa docker compose logs db)"
    gzip -9 "${DIR_TRABAJO}/mautic-db.sql"
    echo "  [OK] dump: $(du -h "${DIR_TRABAJO}/mautic-db.sql.gz" | cut -f1)"
else
    log_aviso "Contenedor db no está corriendo: el backup NO incluirá la BD (¿deseas abortar? Ctrl+C en 10s)"
    sleep 10
fi

log_info "Copiando configuraciones"
install -d "${DIR_TRABAJO}/etc"
cp -a /etc/postfix            "${DIR_TRABAJO}/etc/" 2>/dev/null || true
cp -a /etc/opendkim.conf      "${DIR_TRABAJO}/etc/" 2>/dev/null || true
cp -a /etc/opendkim           "${DIR_TRABAJO}/etc/" 2>/dev/null || true
cp -a /etc/dovecot/conf.d/99-correo.conf "${DIR_TRABAJO}/etc/dovecot-99-correo.conf" 2>/dev/null || true
cp -a /etc/nginx/sites-available/campanas "${DIR_TRABAJO}/etc/nginx-campanas.conf" 2>/dev/null || true
cp -a /etc/aliases            "${DIR_TRABAJO}/etc/" 2>/dev/null || true
cp -a /etc/mailname           "${DIR_TRABAJO}/etc/" 2>/dev/null || true
cp -a "$ARCHIVO_ENV"          "${DIR_TRABAJO}/etc/correo.env" 2>/dev/null || true
cp -a "$DIR_REPO/.env"        "${DIR_TRABAJO}/etc/compose.env" 2>/dev/null || true

log_info "Empaquetando (permisos 600: contiene claves privadas y secretos)"
TAR_GZ="${DESTINO}/backup-campanas-${STAMP}.tar.gz"
tar -czf "$TAR_GZ" -C "$DIR_TRABAJO" .
chmod 600 "$TAR_GZ"

# --- Cifrado opcional ---
if [ "${1:-}" = "--cifrar" ]; then
    SECRETS="/etc/campanas/secrets.env"
    [ -f "$SECRETS" ] || die "Para --cifrar necesitas $SECRETS con BACKUP_PASSPHRASE=... (chmod 600, fuera de Git)"
    # shellcheck disable=SC1090
    set -a; . "$SECRETS"; set +a
    [ -n "${BACKUP_PASSPHRASE:-}" ] || die "BACKUP_PASSPHRASE vacío en $SECRETS"
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -in "$TAR_GZ" -out "${TAR_GZ}.enc" -pass env:BACKUP_PASSPHRASE
    rm -f "$TAR_GZ"
    TAR_GZ="${TAR_GZ}.enc"
    log_info "Backup cifrado: $TAR_GZ"
fi

# --- Retención ---
log_info "Aplicando retención (se conservan $RETENCION copias)"
ls -1t "${DESTINO}"/backup-campanas-*.tar.gz* 2>/dev/null | tail -n +$((RETENCION+1)) | while read -r vieja; do
    rm -f "$vieja" && echo "  [OK] eliminada copia antigua: $vieja"
done

log_info "Backup completado: $TAR_GZ ($(du -h "$TAR_GZ" | cut -f1))"
echo
echo "Recuerda: una copia SOLO en este VPS no protege contra la pérdida del VPS."
echo "Copia $TAR_GZ a almacenamiento externo (rclone/rsync/scp) de forma periódica."

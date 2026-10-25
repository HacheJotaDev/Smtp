#!/usr/bin/env bash
# =====================================================================
# 50-mautic.sh — Docker + Compose (paquetes de Ubuntu) y arranque del
# stack Mautic 7.2.1 + MySQL 8.0 definido en compose.yaml.
# No publica nada más que 127.0.0.1:8080. Idempotente.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
require_os

echo "Acciones que realizará este script:"
echo "  - Instalar docker.io y docker-compose-v2 (repositorio Ubuntu) si faltan"
echo "  - Validar .env (debe existir y sin __RELLENAR__)"
echo "  - 'docker compose up -d' con compose.yaml (Mautic solo en 127.0.0.1:8080)"
echo "  - Esperar salud de MySQL y responder de Mautic en localhost"
confirmar "¿Continuar?"

# --- Docker (idempotente) ---
if ! command -v docker >/dev/null 2>&1; then
    log_info "Instalando Docker desde el repositorio de Ubuntu"
    apt-get update -qq
    paquete_si_falta docker.io
fi
if ! docker compose version >/dev/null 2>&1; then
    log_info "Instalando plugin docker-compose-v2"
    paquete_si_falta docker-compose-v2
fi
systemctl enable --now docker >/dev/null 2>&1 || true

# --- .env de Compose (secretos) ---
if [ ! -f "$DIR_REPO/.env" ]; then
    cp "$DIR_REPO/.env.example" "$DIR_REPO/.env"
    chmod 600 "$DIR_REPO/.env"
    die "He copiado .env.example a .env. Rellena las contraseñas (MYSQL_PASSWORD y
MYSQL_ROOT_PASSWORD) y vuelve a ejecutar este script. .env está en .gitignore."
fi
chmod 600 "$DIR_REPO/.env"
if grep -q "__RELLENAR" "$DIR_REPO/.env"; then
    die ".env contiene __RELLENAR__: edita las contraseñas antes de continuar."
fi

# --- Validación del compose antes de arrancar ---
cd "$DIR_REPO" || die "No se pudo acceder a $DIR_REPO"
log_info "Validando compose.yaml"
docker compose config -q || die "compose.yaml inválido"

# --- Arranque ---
log_info "docker compose up -d"
docker compose up -d

log_info "Esperando salud de la base de datos (hasta 2 min)..."
for _ in $(seq 1 24); do
    ESTADO=$(docker compose ps --format '{{.Health}}' db 2>/dev/null || true)
    [ "$ESTADO" = "healthy" ] && break
    sleep 5
done
[ "${ESTADO:-}" = "healthy" ] || die "MySQL no llegó a 'healthy'. Revisa: docker compose logs db"

log_info "Esperando respuesta HTTP de Mautic (hasta 2 min)..."
for _ in $(seq 1 24); do
    CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080 2>/dev/null || true)
    { [ "$CODIGO" = "200" ] || [ "$CODIGO" = "302" ]; } && break
    sleep 5
done
case "${CODIGO:-}" in
    200|302) echo "  [OK] Mautic responde en 127.0.0.1:8080 (HTTP $CODIGO)" ;;
    *) die "Mautic no responde. Revisa: docker compose logs mautic_web" ;;
esac

log_info "Escuchas expuestas por Docker (solo debe aparecer 127.0.0.1:8080):"
ss -ltnp | grep docker-proxy | sed 's/^/  /' || echo "  [INFO] sin docker-proxy activo"

echo
log_info "FASE MAUTIC COMPLETADA. Siguiente: scripts/60-nginx-tls.sh"
echo "Después de obtener HTTPS, termina el asistente web de Mautic en:"
echo "  https://${FQDN_HOST:-TU_FQDN}  (credenciales de administrador: guárdalas seguras)"

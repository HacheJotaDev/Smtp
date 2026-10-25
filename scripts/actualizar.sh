#!/usr/bin/env bash
# =====================================================================
# actualizar.sh — actualización segura del stack de Mautic (Docker).
# Pasos: backup previo -> pull de la imagen fijada en compose.yaml ->
# up -d -> verificación. Rollback documentado en docs/06-operacion.md.
#
# USO:
#   scripts/actualizar.sh                # actualiza a la versión fijada
#   scripts/actualizar.sh --a-tag X.Y.Z  # cambia el pin a X.Y.Z y actualiza
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root
TAG_NUEVO=""
if [ "${1:-}" = "--a-tag" ]; then
    TAG_NUEVO="${2:-}"
    [ -n "$TAG_NUEVO" ] || die "Uso: actualizar.sh --a-tag 7.2.1"
    echo "$TAG_NUEVO" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "Tag inválido (formato esperado X.Y.Z): $TAG_NUEVO"
fi

cd "$DIR_REPO" || die "No se pudo acceder a $DIR_REPO"
TAG_ACTUAL=$(grep -oP 'image: mautic/mautic:\K[0-9.]+' compose.yaml | head -1)

echo "Actualización del stack de campañas:"
echo "  - Versión fijada actual: ${TAG_ACTUAL:-?}"
if [ -n "$TAG_NUEVO" ]; then
    if [ "$TAG_NUEVO" = "$TAG_ACTUAL" ]; then
        log_info "La versión solicitada ya está fijada en compose.yaml"
    fi
    echo "  - Nueva versión fijada:  $TAG_NUEVO"
fi
echo "  - Se ejecutará backup.sh ANTES de tocar nada"
echo "  - IMPORTANTE: no saltes versiones mayores de Mautic de golpe (7.1->7.2 ok;"
echo "    6->8 no). Lee las notas de la versión antes de continuar."
confirmar "¿Continuar con la actualización?"

log_info "1/4 Backup previo"
bash "$DIR_SCRIPTS/backup.sh" || die "El backup previo falló: actualización ABORTADA (los datos están a salvo)"

if [ -n "$TAG_NUEVO" ] && [ "$TAG_NUEVO" != "$TAG_ACTUAL" ]; then
    log_info "2/4 Cambiando pin de imagen: $TAG_ACTUAL -> $TAG_NUEVO"
    sed -i "s|image: mautic/mautic:${TAG_ACTUAL}|image: mautic/mautic:${TAG_NUEVO}|" compose.yaml \
        || die "No se pudo editar compose.yaml"
else
    log_info "2/4 Manteniendo pin actual"
fi

log_info "3/4 Pull + recreación de contenedores"
docker compose pull
docker compose up -d

log_info "4/4 Verificación"
for _ in $(seq 1 24); do
    CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080 2>/dev/null || true)
    { [ "$CODIGO" = "200" ] || [ "$CODIGO" = "302" ]; } && break
    sleep 5
done
case "${CODIGO:-}" in
    200|302)
        log_info "Mautic responde tras la actualización (HTTP $CODIGO)."
        echo "Versión activa:"
        docker compose exec -T mautic_web php /var/www/html/bin/console --version 2>/dev/null || true
        ;;
    *)
        die "Mautic NO responde tras actualizar. ROLLBACK sugerido:
  1) edita compose.yaml y vuelve a fijar la imagen ${TAG_ACTUAL}
  2) docker compose up -d
  3) si la BD fue migrada, restaura el backup más reciente:
     scripts/restore.sh <backup previo>"
        ;;
esac

log_info "Actualización completada. Ejecuta scripts/80-verificar.sh para la revisión completa."

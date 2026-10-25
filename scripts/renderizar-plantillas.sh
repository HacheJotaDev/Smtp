#!/usr/bin/env bash
# =====================================================================
# renderizar-plantillas.sh — genera las configuraciones reales a partir
# de las plantillas *.plantilla sustituyendo los marcadores {{VAR}}
# con los valores de correo.env.
#
# Uso:
#   scripts/renderizar-plantillas.sh                  # todos los grupos (root, /etc)
#   scripts/renderizar-plantillas.sh postfix          # solo un grupo: postfix|dkim|dovecot|web|cron
#   DESTDIR=/tmp/lab scripts/renderizar-plantillas.sh todas   # laboratorio (no toca /etc)
#
# Seguridad:
#   - Falla si falta correo.env o si aún hay __RELLENAR__.
#   - Respalda cualquier archivo existente antes de sobrescribirlo
#     (salvo en modo laboratorio con DESTDIR).
#   - Nunca escribe secretos: correo.env no contiene contraseñas.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cargar_env

# Variables que las plantillas pueden usar (renderizador las sustituye todas).
VARS_REND=(DOMINIO FQDN_HOST IP_SERVIDOR CORREO_POSTMASTER SELECTOR_DKIM
           RED_DOCKER_CIDR GW_DOCKER PUERTO_MAUTIC_LOCAL
           USUARIO_REBOTES DIRECCION_REBOTES DIR_BASE LOTE_EMAILS)

validar_vars "${VARS_REND[@]}"
sin_marcadores "$ARCHIVO_ENV"

DESTDIR="${DESTDIR:-/}"
if [ "$DESTDIR" != "/" ]; then
    # Modo laboratorio: crea la raíz si falta (nunca borra contenido previo)
    mkdir -p "$DESTDIR"
fi
MODO_LAB=""
[ "$DESTDIR" = "/" ] || MODO_LAB="1"

renderizar() {
    local plantilla="$1" destino="$2"
    local tmp
    tmp="$(mktemp)"
    cp "$plantilla" "$tmp"
    local v val
    for v in "${VARS_REND[@]}"; do
        val="${!v}"
        # Escapar delimitador | y & para sed
        val="${val//|/\\|}"
        val="${val//&/\\&}"
        sed -i "s|{{${v}}}|${val}|g" "$tmp"
    done
    # Garantía: no puede quedar ningún marcador sin sustituir.
    if grep -q "{{[A-Z_]*}}" "$tmp"; then
        log_err "Marcadores sin sustituir en $destino:"
        grep -n "{{[A-Z_]*}}" "$tmp" || true
        rm -f "$tmp"
        die "Renderizado incompleto de $plantilla (revisa correo.env)."
    fi
    if [ -n "$MODO_LAB" ]; then
        mkdir -p "$(dirname "$destino")"
        mv "$tmp" "$destino"
    else
        respaldar_archivo "$destino"
        mkdir -p "$(dirname "$destino")"
        mv "$tmp" "$destino"
    fi
    log_info "Generado: $destino"
}

main() {
    local raiz="${DIR_REPO}"
    local grupo="${1:-todas}"

    # --- Grupo: postfix -----------------------------------------------
    render_postfix() {
        renderizar "$raiz/postfix/main.cf.plantilla"   "$DESTDIR/etc/postfix/main.cf"
        renderizar "$raiz/postfix/master.cf.plantilla" "$DESTDIR/etc/postfix/master.cf"
        renderizar "$raiz/postfix/aliases.plantilla"   "$DESTDIR/etc/aliases"
    }
    # --- Grupo: dkim (OpenDKIM) ---------------------------------------
    render_dkim() {
        renderizar "$raiz/opendkim/opendkim.conf.plantilla"        "$DESTDIR/etc/opendkim.conf"
        renderizar "$raiz/opendkim/tabla-claves.plantilla"         "$DESTDIR/etc/opendkim/TablaClaves"
        renderizar "$raiz/opendkim/tabla-firmantes.plantilla"      "$DESTDIR/etc/opendkim/TablaFirmantes"
        renderizar "$raiz/opendkim/tabla-hosts-internos.plantilla" "$DESTDIR/etc/opendkim/TablaHostsInternos"
    }
    # --- Grupo: dovecot -----------------------------------------------
    render_dovecot() {
        # Solo si hay configuración de sistema destino; en laboratorio se crea
        if [ -d "$DESTDIR/etc/dovecot/conf.d" ] || [ -n "$MODO_LAB" ]; then
            renderizar "$raiz/dovecot/99-correo.conf.plantilla" "$DESTDIR/etc/dovecot/conf.d/99-correo.conf"
        fi
    }
    # --- Grupo: web (nginx; requiere certificado ya emitido) ----------
    render_web() {
        renderizar "$raiz/nginx/mautic.conf.plantilla" "$DESTDIR/etc/nginx/sites-available/campanas"
    }
    # --- Grupo: cron ---------------------------------------------------
    render_cron() {
        # cron.d exige campo de usuario: ya incluido en las plantillas
        renderizar "$raiz/cron/crontab-mautic.plantilla"        "$DESTDIR/etc/cron.d/mautic-campanas"
        renderizar "$raiz/cron/crontab-mantenimiento.plantilla" "$DESTDIR/etc/cron.d/campanas-mantenimiento"
        chmod 644 "$DESTDIR/etc/cron.d/mautic-campanas" "$DESTDIR/etc/cron.d/campanas-mantenimiento" 2>/dev/null || true
    }

    case "$grupo" in
        postfix) render_postfix ;;
        dkim)    render_dkim ;;
        dovecot) render_dovecot ;;
        web)     render_web ;;
        cron)    render_cron ;;
        todas)   render_postfix; render_dkim; render_dovecot; render_web; render_cron ;;
        *) die "Grupo desconocido: $grupo (usa postfix|dkim|dovecot|web|cron|todas)" ;;
    esac

    if [ -z "$MODO_LAB" ]; then
        log_info "Renderizado completo en el sistema real."
        echo "Siguientes pasos habituales: newaliases && postfix check && systemctl reload postfix"
    else
        log_info "Renderizado de laboratorio completo en DESTDIR=$DESTDIR (no se tocó /etc)."
    fi
}

main "$@"

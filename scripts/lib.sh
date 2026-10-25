#!/usr/bin/env bash
# =====================================================================
# lib.sh — funciones comunes de todos los scripts del proyecto.
# NO ejecutar directamente: es una librería (source scripts/lib.sh).
# =====================================================================

# Modo estricto: abortar en error, variable sin definir y fallo en tuberías
set -euo pipefail

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")/.." && pwd)"
# DIR_SCRIPTS lo usan los scripts que hacen source de lib.sh
# shellcheck disable=SC2034
DIR_SCRIPTS="${DIR_REPO}/scripts"
ARCHIVO_ENV="${DIR_REPO}/correo.env"

marca_fecha() { date +%Y%m%d-%H%M%S; }

log_info() { echo "[INFO]  $(date '+%F %T') $*"; }
log_aviso(){ echo "[AVISO] $(date '+%F %T') $*"; }
log_err()  { echo "[ERROR] $(date '+%F %T') $*" >&2; }

die() { log_err "$*"; exit 1; }

# Exige root; si no, detiene el script sin tocar nada.
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Ejecuta como root (sudo -i). Este script modifica el sistema."
}

# Detecta y valida el sistema operativo objetivo.
require_os() {
    if [ ! -r /etc/os-release ]; then
        die "No se puede leer /etc/os-release: SO desconocido."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:24.04) : ;;
        *)
            die "SO no soportado: ${PRETTY_NAME:-desconocido}.
Este proyecto está validado para Ubuntu Server 24.04 LTS.
Puedes revisar las diferencias en docs/03-despliegue.md antes de adaptar."
            ;;
    esac
}

# Confirmación explícita del operador para acciones sensibles.
confirmar() {
    local respuesta
    printf '%s\n' "$1"
    read -r -p "Escribe SI para continuar, otra cosa cancela: " respuesta
    [ "$respuesta" = "SI" ] || die "Cancelado por el operador. No se ha modificado nada."
}

# Carga un fichero de variables si existe (no falla si falta: usar cargar_env_obligatorio).
cargar_env_opcional() {
    local f="$1"
    if [ -f "$f" ]; then
        # shellcheck disable=SC1090
        set -a; # shellcheck disable=SC1090
        . "$f"; set +a
        return 0
    fi
    return 1
}

# Carga correo.env (obligatorio para renderizar e instalar).
cargar_env() {
    cargar_env_opcional "$ARCHIVO_ENV" || die "Falta $ARCHIVO_ENV.
Cópialo:  cp ${DIR_REPO}/correo.env.example ${ARCHIVO_ENV}
Rellénalo y vuelve a ejecutar."
}

# Comprueba que una lista de variables esté definida y no vacía.
validar_vars() {
    local v
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            die "Variable obligatoria sin definir o vacía: $v (revisa $ARCHIVO_ENV)."
        fi
    done
}

# Falla si algún archivo aún contiene marcadores __RELLENAR (o vacíos).
sin_marcadores() {
    local f
    for f in "$@"; do
        if grep -q "__RELLENAR" "$f" 2>/dev/null; then
            die "El archivo $f todavía contiene valores __RELLENAR__ sin sustituir."
        fi
    done
}

# Respalda un archivo antes de sobrescribirlo (nunca destruye sin copia).
respaldar_archivo() {
    local f="$1"
    if [ -e "$f" ]; then
        cp -a "$f" "${f}.orig-$(marca_fecha)"
        log_info "Respaldo creado: ${f}.orig-$(marca_fecha)"
    fi
}

# Instala un paquete solo si falta (idempotencia).
paquete_si_falta() {
    local p="$1"
    if ! dpkg -s "$p" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$p"
    else
        log_info "Paquete ya instalado: $p"
    fi
}

# Ejecuta un comando mostrándolo primero (auditabilidad).
ejecutar() {
    echo "+ $*"
    "$@"
}

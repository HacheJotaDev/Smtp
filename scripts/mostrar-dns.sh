#!/usr/bin/env bash
# =====================================================================
# mostrar-dns.sh — imprime los valores DNS EXACTOS que debes publicar
# para tu dominio (incluida la clave pública DKIM ya generada) y los
# comandos dig para verificarlos. SOLO LECTURA: no publica nada.
# =====================================================================

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cargar_env
validar_vars DOMINIO FQDN_HOST IP_SERVIDOR SELECTOR_DKIM CORREO_POSTMASTER

CLAVE_TXT="/etc/opendkim/claves/${DOMINIO}/${SELECTOR_DKIM}.txt"

echo "=============================================================="
echo " REGISTROS DNS A PUBLICAR (en el panel de tu zona ${DOMINIO})"
echo " Copia los valores TAL CUAL. La clave DKIM mostrada es la"
echo " PÚBLICA; la privada nunca se imprime ni sale del servidor."
echo "=============================================================="
echo
echo "1) Registro A (host de correo y panel):"
echo "   ${FQDN_HOST}.    IN  A     ${IP_SERVIDOR}"
echo
echo "2) MX (recepción de rebotes y correo del dominio):"
echo "   ${DOMINIO}.      IN  MX 10 ${FQDN_HOST}."
echo
echo "3) SPF (un ÚNICO registro TXT para el dominio):"
echo "   ${DOMINIO}.      IN  TXT   \"v=spf1 a mx ip4:${IP_SERVIDOR} -all\""
echo
echo "4) DKIM (selector ${SELECTOR_DKIM}):"
if [ -f "$CLAVE_TXT" ]; then
    echo "   --- Contenido para el registro TXT en ${SELECTOR_DKIM}._domainkey.${DOMINIO} ---"
    # La clave pública es información pública; se muestra en una sola línea.
    KEYLINE=$(tr -d '\n' < "$CLAVE_TXT" | sed 's/;[[:space:]]*/;/g; s/[[:space:]]\+/ /g')
    echo "   ${SELECTOR_DKIM}._domainkey  IN  TXT  ("
    echo "$KEYLINE" | sed 's/^/       /'
    echo "   )"
else
    echo "   [PENDIENTE] Aún no existe $CLAVE_TXT."
    echo "   Ejecuta scripts/30-dkim.sh para generar la clave y vuelve aquí."
fi
echo
echo "5) DMARC (modo observación; endurecer SOLO tras revisar informes):"
echo "   _dmarc  IN  TXT  \"v=DMARC1; p=none; rua=mailto:${CORREO_POSTMASTER}; adkim=r; aspf=r; fo=1\""
echo
echo "6) PTR (DNS inverso): se configura en el PANEL DE TU PROVEEDOR DE VPS:"
echo "   ${IP_SERVIDOR}  ->  ${FQDN_HOST}"
echo
echo "=============================================================="
echo " VERIFICACIÓN (tras publicar y esperar propagación)"
echo "=============================================================="
cat <<EOF

  dig +short A ${FQDN_HOST}
  dig +short MX ${DOMINIO}
  dig +short TXT ${DOMINIO}
  dig +short TXT ${SELECTOR_DKIM}._domainkey.${DOMINIO}
  dig +short TXT _dmarc.${DOMINIO}
  dig +short -x ${IP_SERVIDOR}

Herramientas externas recomendadas (solo lectura):
  - https://mxtoolbox.com/blacklists.aspx  (listas de bloqueo)
  - https://www.mail-tester.com            (puntuación de un envío de prueba)
  - https://www.learndmarc.com             (trazado SPF/DKIM/DMARC paso a paso)
EOF

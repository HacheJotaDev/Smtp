# 05 — Cumplimiento: consentimiento, bajas, supresión y RFC 8058

> Este sistema está diseñado para enviar **solo** a personas que han consentido de forma verificable, y para dejar de hacerlo en cuanto pidan dejar de recibirlo. Está prohibido por diseño: enviar a listas compradas, a direcciones raspadas, ocultar la identidad del remitente o reenviar a quien se ha dado de baja.

## 1. Consentimiento verificable

Antes de importar un contacto, el CSV debe poder responder: **quién, cuándo, por qué canal y con qué evidencia** dio su consentimiento.

Estructura mínima recomendada del CSV (columna `email` obligatoria; el resto recomendadas y verificables por `scripts/validar-csv.py`):

```csv
email,fuente,fecha_consentimiento,evidencia,idioma
ana@example.com,webinar-2026-03,2026-03-14,registro-webinar-form-12,es
luis@example.com,tienda-newsletter,2026-05-02,checkbox-checkout-v2,es
```

- `fuente`: campaña/formulario/tienda que recogió el consentimiento.
- `fecha_consentimiento`: ISO `YYYY-MM-DD`.
- `evidencia`: referencia interna a la prueba (ID de formulario, log, contrato).
- En Mautic, crea **campos personalizados** para estos datos (p. ej. `fuente_consentimiento`, `fecha_consentimiento`) y mápalos al importar. Así el histórico de consentimiento vive con el contacto.

## 2. Validación e importación de CSV

```bash
python3 scripts/validar-csv.py contactos.csv            # informe completo
python3 scripts/validar-csv.py contactos.csv --estricto # aborta con cualquier problema
```

Comprueba: UTF-8, CSV bien formado, sintaxis de email, duplicados, filas con posible inyección (saltos de línea en campos) y presencia de columnas de consentimiento. Mautic además ignora filas inválidas al importar — corrige antes de importar, no después.

## 3. Bajas (unsubscribe)

- Cada email de campaña lleva el enlace estándar de Mautic `{unsubscribe_url}` en el pie. Verifícalo en cada plantilla (T-14 de `07-pruebas.md`).
- La página de baja se sirve por HTTPS vía nginx (`https://FQDN_HOST/unsubscribe/...`).
- La baja marca al contacto como **Do Not Contact** y los segmentos/campañas lo excluyen automáticamente.
- La baja es **inmediata y sin fricción**: nada de "escríbenos para darte de baja".

## 4. Cabeceras List-Unsubscribe y RFC 8058

Mautic ≥5.0 soporta la baja en un clic (PR oficial "RFC 8058 one-click unsubscribe", presente desde 5.0): emite cabeceras del tipo

```
List-Unsubscribe: <https://FQDN_HOST/unsubscribe/...>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
```

para emails masivos. Verificación práctica (no dar nada por sentado): tras enviar una campaña de prueba, inspecciona las cabeceras en un buzón de seed (T-13 de `07-pruebas.md`) y confirma en tu versión instalada. Los receptores grandes (Gmail, Yahoo, Microsoft) exigen estas cabeceras para remitentes de volumen — este proyecto las considera **obligatorias** para campañas.

## 5. Supresión global y procesado de rebotes

- **Do Not Contact (DNC)**: Mautic marca el canal email del contacto. Un contacto DNC no recibe campañas aunque siga en segmentos.
- **Bounces**: `mautic:monitored_email` (cron cada 10 min) lee el buzón interno, clasifica hard/soft, y los hard generan DNC automático. Soft bounces repetidos también acaban en exclusión según la política de la UI.
- **Supresión manual masiva**: para excluir una lista (p. ej. antiguos clientes) sin borrarla, impórtala con el canal email marcado como no deseado o créala como segmento **excluido** en tus campañas. Documenta siempre el origen de la supresión.
- **Quejas**: si recibes una queja directa (respuestas al remitente, FBL de Microsoft), marca DNC manualmente y registra el caso.

## 6. Límites de frecuencia y velocidad

- **Por campaña/plan**: `LOTE_EMAILS` + frecuencia cron (ver `04-entregabilidad.md`).
- **Por contacto**: usa las reglas de frecuencia de Mautic (Frequency rules) para no saturar a la misma persona (p. ej. máx. 2 campañas/semana).
- **Identificación del remitente**: `From` en tu dominio con nombre real de la organización; pie con identificación fiscal/dirección según tu normativa y enlace de contacto (`postmaster@` responde a un buzón real vía alias).

## 7. Protecciones técnicas incluidas

| Riesgo | Mitigación |
|---|---|
| Inyección de cabeceras | Validación de CSV (`validar-csv.py` rechaza saltos de línea en campos); Mautic sanea campos de contacto. |
| CSV malformados | Parser estricto + informe de líneas anómalas. |
| Accesos no autorizados al panel | HTTPS obligatorio, Mautic solo en 127.0.0.1:8080 detrás de nginx, credenciales del asistente inicial. |
| Open relay | `reject_unauth_destination` + prueba activa en `80-verificar.sh`. |
| Reenvío a bajas | DNC de Mautic + procesado de bounces + verificación T-15. |
| Secretos en Git | `.gitignore` + sin credenciales en plantillas (marcadores `{{}}`). |

## 8. Prohibiciones explícitas del proyecto

1. No implementar ni usar técnicas de evasión de filtros (ofuscación, granjas de links, warming artificiales con tráfago falso...).
2. No rotar IPs/dominiós para eludir bloqueos existentes.
3. No saltarse límites de receptores (sin fuzzing de throttling).
4. No continuar enviando a quien se dio de baja (incluye "campañas de reactivación" a DNC).
5. No comprar listas ni raspar direcciones.

Si una campaña necesita lo anterior para "funcionar", el problema es la campaña, no el sistema.

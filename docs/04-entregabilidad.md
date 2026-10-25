# 04 — Entregabilidad: calentamiento, pruebas y diagnóstico

> **Sin promesas de Inbox.** Ninguna técnica garantiza bandeja de entrada. Lo que este proyecto garantiza es: configuración técnica correcta y verificable (SPF/DKIM/DMARC/PTR/TLS), control del ritmo, medición de resultados y criterios objetivos para pausar o acelerar. Distingue siempre tres cosas:
>
> 1. **Aceptación SMTP** — el servidor receptor respondió `250` (no es entrega).
> 2. **Entrega** — el mensaje llegó al sistema del receptor (puede caer en Spam).
> 3. **Ubicación** — Inbox o Spam: la decide el filtro del receptor; solo se **mide** con buzones controlados y herramientas.

## 1. Requisitos previos al primer envío (checklist)

- [ ] El proveedor confirma **puerto 25 saliente** permitido.
- [ ] PTR configurado y coincidente con FQDN/HELO (verificado con dig).
- [ ] A, MX, SPF (`-all`), DKIM (TXT del selector), DMARC (`p=none`) publicados y verificados.
- [ ] `scripts/80-verificar.sh` sin FALLOS; relay activo rechazado; TLS válido.
- [ ] IP limpia en listas: https://mxtoolbox.com/blacklists.aspx (si aparece en alguna: resolver antes de enviar).
- [ ] Dominio "con historia" (algunos meses con web y correo normal ayuda; un dominio recién registrado reduce la confianza inicial).
- [ ] Postmaster Tools (Gmail) y SNDS/JMRP (Microsoft) dados de alta — ver §6.
- [ ] Buzones controlados (seeds) en Gmail y Outlook listos para pruebas.

## 2. Plan de calentamiento de una IP nueva (plantilla configurable)

Regla general: empezar pequeño, crecer ~duplicando cada pocos días **solo si las métricas son sanas**, y pausar al primer problema. Los números son un punto de partida, no una ley; ajústalos a tus resultados.

| Días | Volumen/día aprox. | Condición para avanzar |
|---|---|---|
| 1–3 | 20–50 | Rebotes duros < 2%, sin quejas, aceptación SMTP normal |
| 4–7 | 50–150 | Igual + colocación correcta en seeds |
| 8–14 | 150–400 | Igual + sin bloqueos 4xx persistentes |
| 15–21 | 400–800 | Igual + Postmaster Tools sin incidencias |
| 22–30 | 800–1.200 | Igual; ya cerca del objetivo operativo |
| >30 | objetivo +10%/semana máx. | mantenimiento |

**Cómo se aplica el volumen con este stack:** ajusta `LOTE_EMAILS` (correo.env) y la frecuencia de la línea de `mautic:email:send` en `/etc/cron.d/mautic-campanas`. Ejemplo: día 1 = lote 10 cada 5 min durante 2-3 horas activas ≈ 25-50 envíos. Pausa total = comentar esa línea de cron.

**Reglas de pausa (automática y manual):**
- El `vigia-cola.sh` avisa si la cola crece (posible throttling externo o bloqueo).
- Pausa manual inmediata si: rebotes duros > 5% en una campaña, quejas visibles > 0,1%, o caídas de colocación en seeds.
- Ante errores 4xx masivos de un receptor: reduce volumen hacia ese receptor y revisa `mailq`; los 4xx se reintentan solos (backoff configurado en Postfix).

## 3. Métricas y umbrales de referencia (sector, no promesas)

| Métrica | Rango sano | Acción si se supera |
|---|---|---|
| Rebotes duros | < 2% por campaña | Pausar; purgar lista; validar CSV con `validar-csv.py` |
| Rebotes blandos | < 5% | Vigilar; suelen ser 4xx temporales |
| Quejas spam | < 0,1% | Pausar y revisar contenido/consentimiento |
| Aperturas | depende del sector | tendencia, no valor absoluto |
| Cola Postfix | < 50 en reposo | `postqueue -p` y diagnóstico |

## 4. Pruebas de colocación (seeds) — procedimiento

1. Crea 3–5 buzones reales: al menos 1 Gmail, 1 Outlook/Hotmail, 1 del propio dominio, opcionalmente Yahoo/Zoho.
2. Envía la campaña de prueba a los seeds desde Mautic (así mide aperturas/la cadena real).
3. En cada buzón revisa **las cabeceras completas**:

```
Authentication-Results: mx.google.com;
       dkim=pass header.i=@tudominio.example header.s=mta1
       spf=pass smtp.mailfrom=tudominio.example
       dmarc=pass (p=none ...) header.from=tudominio.example
```

4. Comprueba en qué carpeta cayó (Inbox/Promociones/Spam) y registra el resultado.
5. Herramientas de apoyo: https://www.mail-tester.com (score de un envío puntual), https://www.learndmarc.com (trazado SPF/DKIM/DMARC), https://mxtoolbox.com/deliverycenter.aspx.

Ejemplos de códigos que verás en `/var/log/mail.log` y su lectura:

| Código | Significado | Actuación |
|---|---|---|
| `250 2.0.0 OK` | aceptado | — |
| `421`/`450`/`451` | temporal (greylist, throttle, sobrecarga) | esperar reintento (Postfix backoff); si persiste, reducir ritmo |
| `450 4.7.1 ...rate limited` | exceso de ritmo para ese receptor | reducir lote/frecuencia hacia ese dominio |
| `550 5.1.1` | buzón inexistente | hard bounce: Mautic lo excluye |
| `550 5.7.1 ...blocked`/`spam` | bloqueo por reputación/contenido | revisar blacklists, cabeceras, contenido, quejas |
| `554 5.7.26 ...authentication` | SPF/DKIM/DMARC mal | revisar DNS (docs/02) |
| `553`/`551` | rechazo por política/PTR | revisar HELO/PTR |

## 5. Contenido que también influye

- Identificación clara: `From` real del dominio, pie con identidad de la organización y enlace de baja visible (cumplimiento — ver `05-cumplimiento.md`).
- Relación texto/imagen razonable, sin cadenas de redirección excesivas, dominios de link coherentes con el remitente.
- Un link de baja roto o lento genera quejas: pruébalo en cada campaña (T-14 de `07-pruebas.md`).

## 6. Postmaster Tools y SNDS

- **Google Postmaster Tools** (https://postmaster.google.com): verifica `tudominio.example`; tras algunos días de volumen verás reputación de dominio/IP, tasa de spam y autenticación. Alta gratuita con DNS TXT de verificación.
- **Microsoft SNDS/JMRP** (https://sendersupport.olc.protection.outlook.com/snds/): datos de tráfico hacia Outlook/Hotmail y canal de quejas.
- Ambos son **observatorios**: no arreglan nada por sí solos, pero indican dónde mirar.

## 7. Separación transaccional vs promocional

En un solo VPS comparten IP. Mitigaciones y plan de crecimiento:
- Subdominios de envío distintos (p. ej. `mail.tudominio.example` vs `notificaciones.tudominio.example`) con sus propios registros, y `From` diferenciado.
- Cuando el volumen lo justifique, **segundo VPS + segunda IP** para transaccional (los scripts están pensados para re-ejecutarse en una máquina nueva con otra IP/dominio de envío). No compartas reputación entre categorías cuando sea crítico.

## 8. Limitaciones honestas

- La colocación depende del historial acumulado (IP+dominio+engagement): el calentamiento es gradual **por diseño**, no por burocracia.
- Los receptores cambian sus reglas sin aviso; revisa seeds y Postmaster periódicamente.
- Si el proveedor bloquea el 25 o la IP hereda mala reputación sin remedio, el camino correcto es cambiar de proveedor/IP, no trucos de evasión (que están prohibidos en este proyecto).

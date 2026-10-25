# 07 — Pruebas y criterios de aceptación

> Regla del proyecto: **una prueba que no se ha ejecutado está "SIN EJECUTAR"**, no "pasada". Esta tabla se rellena durante el despliegue real (FASE E/F). Las columnas de Resultado quedan vacías a propósito.

## Convenciones

- Ejecución: desde `/opt/campanas` como root, tras completar `docs/03-despliegue.md`.
- Estados: PASS / FAIL / SIN EJECUTAR.
- El script `scripts/80-verificar.sh` automatiza la mayoría (T01–T10) y devuelve exit≠0 si hay FALLOS.

## Matriz de pruebas

| ID | Prueba | Comando / método | Resultado esperado | Resultado (rellenar) |
|----|--------|------------------|--------------------|--------------------|
| T01 | Instalación limpia en SO limpio | Seguir `03-despliegue.md` bloque a bloque | Todos los scripts terminan sin `die` y con sus `[OK]` | SIN EJECUTAR |
| T02 | Servicios activos | `systemctl is-active postfix opendkim dovecot nginx docker` + `docker compose ps` | todos `active`; mautic_web y db Up/healthy | SIN EJECUTAR |
| T03 | Ausencia de open relay (config) | `postconf -h smtpd_relay_restrictions` | contiene `permit_mynetworks`, `permit_sasl_authenticated`, `reject_unauth_destination` | SIN EJECUTAR |
| T04 | Ausencia de open relay (activa) | `scripts/80-verificar.sh` (sección 3) o manual: EHLO+MAIL FROM externo+RCPT externo sin auth contra 127.0.0.1:25 | rechazo `554`/`553`, nunca `250` al RCPT externo | SIN EJECUTAR |
| T05 | Firewall | `ufw status verbose` | activo; solo 22/25/80/443 permitidos; 143/3306/8080 ausentes | SIN EJECUTAR |
| T06 | TLS válido (SMTP y web) | `openssl s_client -starttls smtp -connect FQDN:25 -brief` y `curl -I https://FQDN` | cert de FQDN, TLS≥1.2, HTTP 200/302 | SIN EJECUTAR |
| T07 | DNS A/PTR coherentes | `dig +short A FQDN` / `dig +short -x IP` | A=IP y PTR=FQDN | SIN EJECUTAR |
| T08 | SPF publicado y correcto | `dig +short TXT DOMINIO` | un único `v=spf1 ... ip4:IP -all` | SIN EJECUTAR |
| T09 | DKIM publicado y consistente | `dig +short TXT SELECTOR._domainkey.DOMINIO` + `opendkim-testkey -d DOMINIO -s SELECTOR -vvv` | TXT con `p=` largo y testkey OK | SIN EJECUTAR |
| T10 | DMARC publicado | `dig +short TXT _dmarc.DOMINIO` | `v=DMARC1; p=none; rua=mailto:...` | SIN EJECUTAR |
| T11 | Envío y recepción de prueba | `scripts/80-verificar.sh --enviar-prueba` | mensaje aceptado (250) y recibido en el buzón destino | SIN EJECUTAR |
| T12 | Autenticación del mensaje (SPF+DKIM+DMARC) | Cabeceras `Authentication-Results` en el buzón seed de T11 | `spf=pass`, `dkim=pass`, `dmarc=pass` | SIN EJECUTAR |
| T13 | Cabeceras List-Unsubscribe (RFC 8058) | Enviar campaña de prueba a seed; ver cabeceras | presentes `List-Unsubscribe` y `List-Unsubscribe-Post: List-Unsubscribe=One-Click` | SIN EJECUTAR |
| T14 | Enlace de baja funcional | Clic en `{unsubscribe_url}` de la prueba T11 | página HTTPS carga; tras confirmar, contacto queda DNC | SIN EJECUTAR |
| T15 | Exclusión efectiva de bajas | Re-lanzar campaña al segmento con el contacto de T14 | el contacto no recibe el envío (visible en estadísticas de Mautic) | SIN EJECUTAR |
| T16 | Rebote permanente procesado | Enviar a `inexistente-xyz@dominio-controlado-externo` y esperar DSN | DSN llega a buzón `devolucion@`; `mautic:monitored_email` lo marca; contacto DNC | SIN EJECUTAR |
| T17 | Rechazo y reintento (4xx) | Acepta una greylist o simula con un dominio que devuelva 4xx | mensaje queda en cola, se reintenta con backoff y sale; nunca se pierde | SIN EJECUTAR |
| T18 | Backup restaurable | `backup.sh` y luego `restore.sh` en ventana/laboratorio + `80-verificar.sh` | verificación sin fallos tras restaurar | SIN EJECUTAR |
| T19 | Secretos fuera de Git | Clon limpio: `git ls-files` no debe listar `.env`, `correo.env` ni `*.private`; y `git grep` sin coincidencias para patrones de token de GitHub, bloques de clave privada ni contraseñas del `.env.example` rellenas | sin coincidencias; solo los `.example` (sin secretos reales) en el índice | SIN EJECUTAR |
| T20 | Recursos y capacidad | `free -m`, `df -h`, `postqueue -p` bajo carga progresiva del calentamiento | RAM <70% sostenida, disco estable, cola <50 en reposo; sin degradación al volumen objetivo | SIN EJECUTAR |

## Pruebas manuales de apoyo (no bloqueantes)

```bash
# Relay manual (equivale a T04):
nc 127.0.0.1 25
#   EHLO probe.local
#   MAIL FROM:<prueba@dominio-externo.example>
#   RCPT TO:<alguien@otro-dominio.example>    → debe responder 554

# Datos personales y secretos en el índice de Git (equivale a T19):
git ls-files | grep -E "\.env$|correo\.env$|\.private$"    # → vacío
git grep -iE "token_de_github|bloque_de_clave_privada"       # → vacío

# Score de un mensaje real (tras T11):
#   https://www.mail-tester.com — enviar el test y esperar ≥9/10
```

## Criterios de aceptación globales (FASE F)

1. T01–T12 en PASS.
2. T13–T15 en PASS antes de la primera campaña real (cumplimiento).
3. T16–T17 en PASS antes de escalar volumen (resiliencia de la cola).
4. T18 en PASS al menos una vez antes de producción y trimestralmente.
5. T19 en PASS en cada push (revisión en la FASE C incluida).
6. T20 monitorizado durante todo el calentamiento; objetivos de `04-entregabilidad.md` §3.

## Registro de ejecución

| Fecha | ID | Operador | Resultado | Notas |
|-------|----|----------|-----------|-------|
|       |    |          |           |       |

(El registro de ejecución real se mantiene fuera del repo si incluye datos de producción, o aquí si solo contiene PASS/FAIL.)

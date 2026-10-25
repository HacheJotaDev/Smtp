# 06 — Operación: cron, monitorización, backups, actualizaciones y runbook

## 1. Tareas programadas (qué corre y por qué)

Tras `renderizar-plantillas.sh` existen dos ficheros en `/etc/cron.d/`:

**`mautic-campanas`** (generado desde `cron/crontab-mautic.plantilla`):

| Tarea | Frecuencia | Función |
|---|---|---|
| `mautic:segments:update` | 10 min | Recalcula segmentos |
| `mautic:campaigns:update` | 5 min | Pobla campañas desde segmentos |
| `mautic:campaigns:trigger` | 5 min | Ejecuta eventos de campaña |
| `mautic:email:send --limit=LOTE` | 5 min | **Envío real** (cola). LOTE en correo.env |
| `mautic:monitored_email` | 10 min | Rebotes/bajas del buzón IMAP |
| `mautic:maintenance:cleanup` | diaria | Limpieza de datos antiguos |

**`campanas-mantenimiento`**: `vigia-cola.sh` (10 min), `backup.sh` (diario 02:30), `certbot renew` (semanal + timer propio de certbot).

Los logs de cron van a `/var/log/campanas/mautic-cron.log`, `vigia.log`, `backup.log`. Verifica que tu versión de Mautic expone los comandos esperados:

```bash
docker compose -f /opt/campanas/compose.yaml exec mautic_web \
  php /var/www/html/bin/console list mautic
```

**Alternativa oficial** (patrón de la imagen): un segundo servicio con `DOCKER_MAUTIC_ROLE: mautic_cron` y sin cron del host. Se describe en `compose.yaml`; el cron del host se prefiere aquí por control fino del ritmo y pausa trivial.

## 2. Monitorización

- **Vigía local** (`vigia-cola.sh`, cada 10 min): cola de Postfix > 200, disco > 85%, servicios caídos, milter DKIM caído, contenedor Mautic parado. Alerta por correo a `CORREO_POSTMASTER` con cooldown de 1 h por tipo.
- **Limitación honesta**: si Postfix está caído, la alerta no puede salir por correo. Añade un monitor externo de uptime (UptimeRobot, healthchecks.io con ping al `vigia-cola.sh`, etc.) — fuera de alcance de este repo, pero muy recomendable.
- **Métricas de correo**: revisa a diario durante el calentamiento y luego 2–3 veces por semana: `postqueue -p`, `/var/log/mail.log` (busca `status=sent`, `status=deferred`, `status=bounced`), panel de Mautic (aperturas/clicks/bounces por campaña), Postmaster Tools y SNDS (semanal).

```bash
# Resumen rápido de resultados del día
grep -c "status=sent" /var/log/mail.log
grep -c "status=deferred" /var/log/mail.log
grep -c "status=bounced" /var/log/mail.log
```

## 3. Copias de seguridad

**Qué incluye `backup.sh`** (diario, retención 7): dump transaccional de la BD Mautic (vía `docker compose exec`, credenciales nunca en el host), `/etc/postfix`, `/etc/opendkim*` (**incluye la clave privada DKIM**), Dovecot, nginx, aliases, `correo.env` y `.env`. Tar con permisos 600. Opcional `--cifrar` con passphrase en `/etc/campanas/secrets.env`.

**Regla de oro**: una copia que solo existe en el VPS no es un backup. Sincroniza `/var/backups/campanas/` a almacenamiento externo (rclone/rsync/scp) **cifrado** (usa `--cifrar`).

**Prueba de restauración obligatoria** antes de producción y al menos una vez al trimestre:

```bash
scripts/backup.sh
# en una ventana de mantenimiento (o mejor, en un VPS de laboratorio):
scripts/restore.sh /var/backups/campanas/backup-campanas-<fecha>.tar.gz
```

`restore.sh` respalda el estado actual antes de sobrescribir (pre-restore-*.tar.gz), restaura configs y BD, y termina ejecutando `80-verificar.sh`.

## 4. Actualizaciones

```bash
apt list --upgradable          # parches del sistema (unattended-upgrades cubre seguridad)
scripts/actualizar.sh          # Mautic: backup + pull + up -d + verificación
scripts/actualizar.sh --a-tag 7.2.2   # cambiar la versión fijada (ejemplo)
```

Reglas:
- **No saltar versiones mayores** de Mautic (7.1→7.2 sí; 6→8 no). Lee las notas de la versión antes del salto.
- `actualizar.sh` hace backup previo y verifica HTTP; si falla, sugiere el rollback exacto.

## 5. Rollback (procedimiento)

1. Vuelve al pin anterior: `scripts/actualizar.sh --a-tag <versión-anterior>`.
2. Si la BD fue migrada por la versión nueva y no funciona hacia atrás: `scripts/restore.sh <backup previo a la actualización>` (los backups de antes de cada actualización están garantizados porque `actualizar.sh` los ejecuta primero).
3. Si el problema es de Postfix/DKIM tras un cambio: los `.orig-<fecha>` creados por cada script permiten restaurar el fichero concreto (`cp /etc/postfix/main.cf.orig-<fecha> /etc/postfix/main.cf && postfix check && systemctl reload postfix`).

## 6. Runbook de incidentes

### 6.1 Cola creciendo / envíos detenidos
```bash
postqueue -p | tail -30                 # ¿qué dominio y qué error?
grep "status=deferred" /var/log/mail.log | tail -10
```
- 4xx hacia un receptor: throttling → reduce `LOTE_EMAILS` o frecuencia; espera backoff.
- `Connection refused/timed out` generalizado: revisa conectividad/puerto 25 y si el proveedor bloqueó algo.
- Muchos `5xx`: ve a 6.2 o 6.3.

### 6.2 Sospecha de inclusión en blacklist
```bash
# Consulta tu IP en las listas principales (mxtoolbox, multirbl.valli.org)
grep -E "5(5[0-9])" /var/log/mail.log | tail -20   # códigos exactos
```
- Identifica la lista y su política de delisting (formularios oficiales).
- Antes de pedir delisting: corrige la causa (rebotes, quejas, contenido). Pausa campañas hasta resolver.
- Gmail/Outlook: usa Postmaster/SNDS y sus formularios oficiales.

### 6.3 Pico de rebotes o quejas
1. **Pausa el envío** (comenta la línea de `mautic:email:send` en `/etc/cron.d/mautic-campanas`).
2. Exporta los bounces de la campaña en Mautic y clasifica (5.1.1 = lista sucia; 5.7.x = autenticación/reputación).
3. Purga la fuente del CSV (`validar-csv.py --estricto`), revisa consentimiento y contenido.
4. Reanuda con volumen reducido solo con métricas verdes.

### 6.4 DKIM dejó de firmar (o milter caído)
```bash
systemctl status opendkim; journalctl -u opendkim -e
ss -ltn | grep 8891
```
- Con `milter_default_action=tempfail` el envío se retrasa (no sale sin firmar): es el comportamiento esperado, arregla el milter y la cola se vaciará.

### 6.5 Certificado caducado
```bash
certbot renew; systemctl reload nginx postfix dovecot
# y revisa por qué falló el timer: systemctl list-timers | grep certbot
```

### 6.6 Contenedor Mautic caído
```bash
cd /opt/campanas && docker compose ps
docker compose logs --tail=50 mautic_web db
docker compose up -d
```

## 7. Mantenimiento de seguridad (mensual)

- `apt list --upgradable` y revisar avisos de unattended-upgrades.
- Revisar `last -a` y `journalctl -u ssh` (intentos de acceso).
- Revisar `ufw status verbose` (¿reglas nuevas inesperadas?).
- Revisar permisos: `stat -c '%a %U:%G %n' /etc/opendkim/claves/*/* /opt/campanas/.env`.
- Verificar backups recientes existen y se han copiado fuera.
- Revisar informes DMARC (tendencia de `spf=pass`/`dkim=pass`).

## 8. Procedimiento de recuperación de desastre (resumen)

1. Provisiona VPS nuevo con Ubuntu 24.04 + IP (pide PTR).
2. Clona el repo, restaura `correo.env` y `.env` desde el backup.
3. Ejecuta bloques 4–12 de `docs/03-despliegue.md` (scripts idempotentes).
4. `scripts/restore.sh <backup>` para BD y configs.
5. Actualiza DNS (A de la nueva IP) y PTR; espera propagación.
6. `scripts/80-verificar.sh` y reanudar con volumen reducido (la IP nueva recalienta: `04-entregabilidad.md`).

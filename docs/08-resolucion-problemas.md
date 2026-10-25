# 08 — Resolución de problemas

## 1. El proveedor bloquea el puerto 25 saliente

**Síntoma:** `00-preflight.sh` falla la prueba de `/dev/tcp/gmail-smtp-in.l.google.com/25`; o `status=deferred (Connection timed out)` hacia todos los dominios.

**Diagnóstico:** pide confirmación escrita al proveedor. Muchos VPS de consumo lo bloquean por defecto (por anti-spam) y solo lo abren tras verificación de identidad/uso.

**Decisión de arquitectura:** si está y seguirá bloqueado, **el plan de envío directo se detiene aquí**. Este proyecto no usa APIs comerciales como parche (requisito explícito). Opciones legítimas: cambiar a un proveedor que permita el 25 con verificación, o repensar el requisito. No hay un "truco" que resuelva un bloqueo de red sin degradar el proyecto.

## 2. Postfix no arranca tras renderizar

```bash
postfix check                 # verá el error concreto
journalctl -u postfix -e
```
Causas típicas: ruta de certificado inexistente (ejecuta `60-nginx-tls.sh` antes de exigir TLS... o revert con `*.orig-*`), error de sintaxis en main.cf editado a mano (edita la plantilla, no el render), alias sin `newaliases`.

## 3. Mensajes salen sin firma DKIM

```bash
grep dkim /var/log/mail.log | tail
systemctl status opendkim; ss -ltn | grep 8891
opendkim-testkey -d DOMINIO -s SELECTOR -vvv
```
- `opendkim[...]: can't load key`: permisos. La clave debe ser `opendkim:opendkim`, 600 (`30-dkim.sh` lo fuerza).
- Firma ausente en cabeceras: ¿el remitente coincide con la `TablaFirmantes` (`*@DOMINIO`)? ¿El milter está en `smtpd_milters`? ¿Estás mirando un correo de `postfix sendmail` local? (también firma: `non_smtpd_milters`).
- `key unavailable ... DNS query timeout`: el TXT DKIM no está publicado o aún no propaga.

## 4. Gmail marca spam o da 4xx/5xx

1. Verifica la cadena completa: T07–T12 de `07-pruebas.md` (PTR, SPF, DKIM, DMARC, alineación del From).
2. Revisa `Authentication-Results` en un seed: si `dkim=fail` → problema de firma; si `spf=fail` → SPF/IP; si todo pass y aún así spam → contenido/engagement/historial: revisa `04-entregabilidad.md` (es lo normal en IP nueva: calentamiento).
3. Postmaster Tools: reputación y tasa de spam. Microsoft: SNDS.

## 5. Los rebotes no llegan al buzón

```bash
dig +short MX DOMINIO                       # ¿apunta a FQDN_HOST?
ss -ltn | grep ':25 '
grep 'devolucion' /etc/aliases && newaliases
ls -la /home/rebotes/Maildir/new/
tail -f /var/log/mail.log                   # ¿"delivered to maildir"?
```
- Si el DSN llega pero Mautic no lo procesa: revisa en la UI la configuración de Monitored Email (host `host.docker.internal`, puerto 143, usuario `rebotes`) y prueba credenciales con `doveadm auth test rebotes`. También comprueba el cron: `grep monitored /etc/cron.d/mautic-campanas`.

## 6. Mautic no puede enviar (timeout SMTP desde el contenedor)

```bash
docker compose -f /opt/campanas/compose.yaml exec mautic_web getent hosts host.docker.internal
# debe devolver 172.20.0.1 (o el gateway de la red)
```
- ¿Postfix escucha? `ss -ltn | grep ':25 '` (inet_interfaces=all).
- ¿El CIDR en `correo.env` (`RED_DOCKER_CIDR`) coincide con la subred real de compose? (`docker network inspect campanas_correo`).
- ¿uFW bloquea tráfico interno del bridge? ufw filtra FORWARD; con la red default de Docker no suele afectar a host←container.

## 7. Certbot no puede emitir certificado

- El A debe apuntar a la IP **antes** (`dig +short A FQDN`): `60-nginx-tls.sh` lo comprueba y aborta si no.
- ¿uFW permite 80? ¿otro servicio en el 80? `ss -ltnp | grep ':80 '`.
- Rate limits de Let's Encrypt (5 fallos/hora): espera; usa `--staging` para pruebas de infraestructura y revoca/reemite en real después.

## 8. Cola llena de mensajes antiguos

```bash
postqueue -p                # inspección
postqueue -f                # forzar reintento (tras resolver la causa)
postsuper -d ALL deferred   # ⚠️ BORRA la cola diferida — solo si sabes qué contienen
```
Nunca borres la cola para "arreglar" un rebote masivo sin entender la causa (documenta en el runbook 6.1 de `06-operacion.md`).

## 9. Disco lleno / logs enormes

- Rotación: `/etc/logrotate.d/postfix-correo` (28 días comprimidos). ¿Está instalada? (`20-postfix.sh`).
- `/var/lib/docker` crece con logs de contenedores: limita el driver json-file en `/etc/docker/daemon.json` (`max-size`) — decisión del operador, fuera de los scripts por ser cambio global de Docker.

## 10. ufw me cortó el SSH

Accede por consola del proveedor (VNC/rescue) y ejecuta `ufw disable`; corrige `IPS_ADMIN_UFW` en `correo.env` y re-aplica `70-firewall.sh`. Por eso el script pide confirmación y conviene tener sesión duplicada.

## 11. "Relay access denied" al enviar desde fuera con 587

- 587 exige **TLS + autenticación**: prueba `swaks --server FQDN:587 -tls --auth LOGIN --au usuario --ap 'pass'`.
- El usuario debe existir en el sistema (dovecot SASL usa cuentas Unix). Crea uno de envío si lo necesitas (`useradd -m -s /usr/sbin/nologin envios && passwd envios`) — úsalo solo por 587 con TLS.

## 12. Docker publicó un puerto en 0.0.0.0 y ufw no lo bloquea

Comportamiento conocido (Docker salta ufw). Corrige la publicación en `compose.yaml` para que sea `127.0.0.1:8080:80` (así está por defecto) y `docker compose up -d`. Nunca publiques la BD ni Mautic en todas las interfaces.

## 13. Cron de Mautic no hace nada

```bash
grep CRON /var/log/syslog | tail
tail /var/log/campanas/mautic-cron.log
docker compose -f /opt/campanas/compose.yaml exec mautic_web php /var/www/html/bin/console mautic:email:send --limit=1   # manual
```
- ¿`DIR_BASE` correcto en `correo.env` antes de renderizar? ¿Existe `/var/log/campanas`? (`10-base.sh` lo crea).

## 14. Nada de lo anterior funciona

`scripts/diagnostico.sh --fichero` genera un informe completo (sin secretos) para analizar la situación con calma o pedirme ayuda con los datos en la mano.

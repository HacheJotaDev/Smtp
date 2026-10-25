# 03 — Despliegue en el VPS (comandos exactos, orden y explicación)

> **Nada de este documento se ejecuta automáticamente.** El operador (tú) ejecuta cada bloque, lee la salida y decide. Los scripts piden confirmación explícita (`SI`) antes de modificar el sistema, son idempotentes y respaldan todo archivo que tocan.
>
> Requisitos previos: VPS con **Ubuntu Server 24.04 LTS**, 2 vCPU/2 GB (recomendado 4 GB), IP dedicada, acceso SSH con clave, dominio con control del DNS y **puerto 25 saliente permitido por el proveedor** (confírmalo antes de empezar: si está bloqueado, el plan de envío directo se detiene — ver `08-resolucion-problemas.md` §1).

## Bloque 1 — Comprobaciones iniciales del VPS

```bash
# ¿Qué soy, qué tengo y qué hay a la escucha? (solo lectura)
cat /etc/os-release                     # debe decir Ubuntu 24.04
free -m; df -h /                        # RAM y disco
systemd-detect-virt                     # entorno de virtualización
ss -ltnp                                # puertos ya ocupados (no debe haber 25/80/443/143/3306)
ip -4 addr show scope global            # IP real del interfaz
timedatectl set-ntp true                # reloj sincronizado (firma DKIM lo exige)
```

Crea y añade tu clave SSH si aún no lo hiciste, y desactiva login por contraseña **solo cuando verifiques que la clave funciona**:

```bash
# /etc/ssh/sshd_config.d/99-hardening.conf
#   PasswordAuthentication no
#   PermitRootLogin prohibit-password
systemctl restart ssh     # ¡mantén la sesión abierta hasta verificar el acceso!
```

## Bloque 2 — Clonar el repositorio y rellenar variables

```bash
apt update && apt install -y git
git clone https://github.com/HacheJotaDev/Smtp.git /opt/campanas
cd /opt/campanas

# Variables del sistema (sin secretos): dominio, IP, FQDN, selector...
cp correo.env.example correo.env && nano correo.env
# Secretos de la BD de Mautic:
cp .env.example .env && nano .env       # contraseñas fuertes: openssl rand -base64 24
```

## Bloque 3 — Preflight (solo lectura; puede abortar con fallos)

```bash
scripts/00-preflight.sh
```

Comprueba SO, recursos, puertos libres, IP pública vs declarada, A/PTR y **conectividad saliente por el 25**. Si falla el test del 25, contacta con el proveedor antes de nada: no se degrada la arquitectura para "que funcione".

## Bloque 4 — Actualización de paquetes y base

```bash
scripts/10-base.sh --con-upgrade
```

Instala postfix, opendkim(+tools), dovecot-core/imapd, nginx, certbot, rsyslog, ufw, swaks, dnsutils y `unattended-upgrades` (parches de seguridad automáticos), y configura el logging de correo.

## Bloque 5 — Postfix

```bash
scripts/20-postfix.sh
```

Crea el usuario de rebotes, renderiza `main.cf`/`master.cf`/`aliases` desde plantilla (con respaldo), ejecuta `postfix check` y **autocomprueba que `reject_unauth_destination` está presente** (anti open-relay) antes de arrancar.

## Bloque 6 — DKIM

```bash
scripts/30-dkim.sh
```

Genera clave 2048 si no existe (nunca la regenera ni la imprime), configura el milter en `127.0.0.1:8891` y arranca OpenDKIM. La prueba DNS de este paso fallará hasta publicar el TXT: es lo esperado.

## Bloque 7 — Dovecot interno

```bash
scripts/40-dovecot.sh
```

Configura IMAP **solo para loopback + red Docker** y el socket SASL de Postfix. Verifica que no escucha en 0.0.0.0.

## Bloque 8 — Docker + Mautic + MySQL

```bash
scripts/50-mautic.sh
```

Instala `docker.io`/`docker-compose-v2` del repositorio Ubuntu (si faltan), valida `.env` (rechaza `__RELLENAR__`), valida `compose.yaml` y arranca el stack. Mautic queda en `127.0.0.1:8080`.

## Bloque 9 — DNS (antes de TLS y de DKIM-verde)

Publica los registros de `dns/registros-dns.plantilla.md` en tu panel DNS:
A, MX, SPF, DMARC y (tras el Bloque 6) el TXT DKIM que imprime:

```bash
scripts/mostrar-dns.sh        # valores exactos + comandos dig de verificación
```

Y en el **panel del proveedor del VPS** fija el PTR: `TU_IP → mail.tudominio.example`.
Espera propagación y verifica:

```bash
dig +short A mail.tudominio.example; dig +short -x TU_IP
dig +short TXT tudominio.example; dig +short TXT mta1._domainkey.tudominio.example
dig +short TXT _dmarc.tudominio.example; dig +short MX tudominio.example
```

## Bloque 10 — nginx + HTTPS

```bash
scripts/60-nginx-tls.sh
```

Verifica que el A apunta a tu IP (aborta si no), obtiene el certificado Let's Encrypt, despliega el vhost TLS completo y deja el hook de renovación que recarga postfix/dovecot/nginx. Tras esto: entra en `https://mail.tudominio.example`, completa el **asistente de Mautic** (crea el usuario administrador; BD ya preconfigurada) y configura:

- **Email settings → SMTP**: `host.docker.internal`, puerto 25, sin autenticación (red interna), encryption `none`.
- **Bounce / return path**: dirección `devolucion@tudominio.example`.
- **Monitored Email (bounces)**: IMAP `host.docker.internal:143`, usuario `rebotes`, la contraseña que le fijes (`passwd rebotes`), carpeta INBOX.

> Los nombres exactos de los campos pueden variar según la versión de Mautic; verifica contra la UI instalada. Los conceptos y la topología no cambian.

## Bloque 11 — Cron de Mautic y mantenimiento

```bash
# Con correo.env rellenado (DIR_BASE=/opt/campanas):
scripts/renderizar-plantillas.sh cron      # genera /etc/cron.d/mautic-campanas y campanas-mantenimiento
# Fija la contraseña del buzón de rebotes:
passwd rebotes
```

El cron procesa segmentos, campañas y la cola con lote `LOTE_EMAILS` (empieza en 50; súbelo con criterio según `04-entregabilidad.md`).

## Bloque 12 — Firewall

```bash
scripts/70-firewall.sh
```

ufw: 22 (restringido si definiste `IPS_ADMIN_UFW`), 25, 80, 443. Todo lo demás denegado. **Ten otra sesión SSH abierta** al aplicarlo, por seguridad.

## Bloque 13 — Pruebas SMTP y de autenticación

```bash
# Prueba activa de anti-relay + TLS + DNS (solo lectura salvo lo que digas):
scripts/80-verificar.sh

# Envío controlado de UN mensaje (pasa por Postfix+DKIM):
scripts/80-verificar.sh --enviar-prueba
```

Revisa en el buzón destino la cabecera `Authentication-Results` (debe mostrar `spf=pass` y `dkim=pass` con el DNS publicado).

## Bloque 14 — Logs, cola y verificación final

```bash
tail -f /var/log/mail.log          # entregas, TLS, DKIM
postqueue -p                       # cola (debe estar vacía en reposo)
docker compose -f /opt/campanas/compose.yaml ps
scripts/80-verificar.sh            # resumen completo
```

## Bloque 15 — Backup, actualización y restauración

```bash
# Primera copia y prueba de restauración (¡hacerla ANTES de producción!):
scripts/backup.sh
scripts/restore.sh /var/backups/campanas/backup-campanas-<fecha>.tar.gz   # en lab/ventana

# Ciclo operativo:
scripts/actualizar.sh              # backup previo + pull + verificación
scripts/actualizar.sh --a-tag 7.2.2 # (ejemplo) cambiar versión fijada
```

## Orden de fases y criterio de avance

| Fase | Script | Criterio observable para avanzar |
|---|---|---|
| Base | 10-base | paquetes instalados + `/var/log/mail.log` existe |
| Postfix | 20-postfix | `postfix check` OK + restricciones verificadas + servicio activo |
| DKIM | 30-dkim | milter 8891 a la escucha + clave 600 |
| Dovecot | 40-dovecot | `doveconf -n` OK + escuchas solo internas |
| Mautic | 50-mautic | HTTP 200/302 en 127.0.0.1:8080 + MySQL healthy |
| DNS | (panel) | dig correcto en A/PTR/MX/SPF/DKIM/DMARC |
| TLS | 60-nginx-tls | https://FQDN responde + cert >7 días |
| Firewall | 70-firewall | `ufw status` activo con solo 22/25/80/443 |
| Verificación | 80-verificar | 0 FALLOS |
| Producción | — | solo tras el plan de calentamiento de `04-entregabilidad.md` |

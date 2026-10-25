# Smtp — Servidor autohospedado de campañas de correo

Sistema de envío de campañas de correo autohospedado para un único VPS, **sin APIs comerciales de envío** (no SES/SendGrid/Mailgun/Brevo). El flujo es: Mautic (gestión de campañas) → SMTP directo → Postfix (MTA) → Internet, con firma DKIM, SPF, DMARC y gestión de rebotes propias.

> **Aviso honesto de entregabilidad:** ninguna configuración técnica garantiza la bandeja de entrada (Inbox). Este proyecto implementa las medidas técnicas estándar y las herramientas para **medir** la entregabilidad real (cabeceras `Authentication-Results`, pruebas con buzones controlados, Postmaster Tools, monitorización de rebotes y quejas). Diferencia entre *aceptación SMTP*, *entrega* y *clasificación en Inbox*: ver `docs/04-entregabilidad.md`.

> **Uso aceptable:** este sistema es exclusivamente para envío a destinatarios con **consentimiento verificable**. Está diseñado para facilitarlo (bajas, supresión, RFC 8058, procesado de rebotes) y **no** incluye ni admite mecanismos para evadir filtros antispam, ocultar identidad o enviar a listas compradas. Ver `docs/05-cumplimiento.md`.

## Arquitectura (resumen)

```
                    Internet
                       ▲ │
                    25 │ ▼ 25 (rebotes entrantes, DSN)
        ┌──────────────┴───────────────────┐
        │  VPS Ubuntu 24.04 LTS            │
        │                                  │
        │  Postfix (nativo, MTA saliente)  │◄─── mynetworks: 127.0.0.1 + 172.20.0.0/24
        │   ├─ OpenDKIM (firma)            │
        │   ├─ Dovecot IMAP (SOLO interno) │◄─── buzón de rebotes (usuario local)
        │   └─ SASL para envío 587         │
        │                                  │
        │  Docker (red fija 172.20.0.0/24) │
        │   ├─ mautic_web  :80 (127.0.0.1:8080) ── nginx 443 (TLS) ◄── operador
        │   └─ mysql 8.0   (sin puertos públicos)
        └──────────────────────────────────┘
```

Decisiones principales y su justificación completa: `docs/01-arquitectura.md`.

| Componente | Rol | Despliegue |
|---|---|---|
| Ubuntu 24.04 LTS | SO base del VPS | Proveedor |
| Postfix 3.8 | MTA saliente + recepción de rebotes | Nativo (paquetes distro) |
| OpenDKIM 2.11 | Firma DKIM de todo lo saliente | Nativo |
| Dovecot (core+imapd) | Buzón IMAP de rebotes y SASL para 587 — **solo loopback/red interna** | Nativo |
| Mautic 7.2.1 | Campañas, contactos, bajas, automatización | Docker Compose (imagen oficial fijada) |
| MySQL 8.0 | Base de datos de Mautic | Docker Compose (sin puertos expuestos) |
| nginx + certbot | HTTPS para la interfaz y páginas de baja | Nativo |
| ufw | Firewall | Nativo |

## Requisitos

- VPS con **Ubuntu Server 24.04 LTS**, mínimo 2 vCPU / 2 GB RAM (recomendado 4 GB), 20 GB disco.
- **Puerto 25 saliente permitido por el proveedor** (verificar antes de empezar; si está bloqueado, el plan de envío directo se detiene — no se sustituye por APIs externas).
- Un dominio propio con acceso a su DNS.
- Registro **PTR** configurable en el panel del proveedor del VPS.
- IP pública dedicada (no compartida por otros emisores).

## Inicio rápido (resumen)

El procedimiento completo, bloque a bloque y con explicación, está en **`docs/03-despliegue.md`**. Resumen:

```bash
# 1. En el VPS, como root
apt update && apt install -y git
git clone https://github.com/HacheJotaDev/Smtp.git /opt/campanas
cd /opt/campanas

# 2. Rellenar variables (sin secretos en Git)
cp correo.env.example correo.env && nano correo.env
cp .env.example .env && nano .env          # contraseñas BD

# 3. Comprobaciones previas (solo lectura)
scripts/00-preflight.sh

# 4. Instalación por fases (cada script es idempotente y pide confirmación)
scripts/10-base.sh && scripts/20-postfix.sh && scripts/30-dkim.sh \
  && scripts/40-dovecot.sh && scripts/50-mautic.sh && scripts/60-nginx-tls.sh \
  && scripts/70-firewall.sh

# 5. Publicar DNS según dns/registros-dns.plantilla.md y verificar
scripts/mostrar-dns.sh
scripts/80-verificar.sh
```

## Estructura del repositorio

```
├── README.md                    este archivo
├── compose.yaml                 Mautic + MySQL (Docker Compose)
├── .env.example                 variables con secretos (BD) — .env va en .gitignore
├── correo.env.example           variables del sistema (dominio, IP, selector) — correo.env en .gitignore
├── docs/
│   ├── 01-arquitectura.md       componentes, decisiones, red y firewall
│   ├── 02-dns.md                DNS, SPF, DKIM, DMARC, PTR, DNSSEC, MTA-STS
│   ├── 03-despliegue.md         comandos exactos para el VPS, paso a paso
│   ├── 04-entregabilidad.md     calentamiento de IP, pruebas, 4xx/5xx, Postmaster Tools
│   ├── 05-cumplimiento.md       consentimiento, bajas, RFC 8058, supresión, CSV
│   ├── 06-operacion.md          cron, monitorización, backups, actualizaciones, runbook
│   ├── 07-pruebas.md            criterios de aceptación con comandos y resultados esperados
│   └── 08-resolucion-problemas.md  fallos comunes y diagnóstico
├── dns/registros-dns.plantilla.md   tabla de registros a publicar (valores a sustituir)
├── postfix/                     plantillas main.cf, master.cf, aliases, logrotate
├── opendkim/                    plantilla opendkim.conf y tablas
├── dovecot/                     configuración mínima IMAP interno
├── nginx/                       plantilla vhost Mautic
├── cron/                        plantillas de cron.d (Mautic y mantenimiento)
└── scripts/                     instalación idempotente, render, verificación, backup, watchdog
```

## Seguridad

- **Secretos fuera de Git**: `.env`, `correo.env`, claves DKIM privadas y copias de seguridad están en `.gitignore`. Las plantillas solo contienen marcadores `{{VARIABLE}}`.
- **Sin open relay**: `smtpd_relay_restrictions` con `reject_unauth_destination` verificado por `scripts/80-verificar.sh` (prueba activa de relay).
- **Superficie mínima**: solo 22/25/80/443 abiertas en ufw; Dovecot y la BD solo en loopback/red interna de Docker; Mautic publicado únicamente en `127.0.0.1:8080` detrás de nginx.
- **Idempotencia y confirmación**: los scripts detectan SO, exigen root, respaldan archivos existentes antes de tocarlos y piden confirmación explícita (`SI`) para acciones irreversibles.

## Estado del proyecto

- [x] FASE A — inspección y arquitectura
- [x] FASE B — documentación, plantillas y scripts
- [x] FASE C — revisión de seguridad y validación sintáctica
- [x] FASE D — pruebas de laboratorio (render de plantillas y validaciones locales, sin envío real)
- [ ] FASE E — despliegue en VPS (pendiente de tu ejecución con `docs/03-despliegue.md`)
- [ ] FASE F — verificación operativa y puesta en producción

## Licencia y responsabilidad

El operador es responsable del cumplimiento del GDPR/LOPDGDD y de la normativa aplicable al correo comercial de su jurisdicción, así como de las políticas de su proveedor de VPS.

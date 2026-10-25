# 01 — Arquitectura y decisiones técnicas

## 1. Visión general

Sistema de envío de campañas autohospedado para **un único VPS**, con control total de la infraestructura SMTP: sin APIs comerciales (SES/SendGrid/Mailgun/Brevo). La plataforma de campañas (Mautic) envía **exclusivamente por SMTP** contra Postfix local; los rebotes se recogen en un buzón propio y se procesan con la función de Monitored Email de Mautic. El volumen objetivo previsto es superior a 1.000 correos/día, con un plan de calentamiento progresivo antes de alcanzarlo (ver `04-entregabilidad.md`).

```
                    Internet
                       ▲ │
                    25 │ ▼ 25 (DSN/rebotes entrantes al envelope sender)
        ┌──────────────┴───────────────────┐
        │  VPS Ubuntu 24.04 LTS            │
        │                                  │
        │  Postfix (nativo, MTA)           │◄── mynetworks: 127.0.0.1 + 172.20.0.0/24
        │   ├─ OpenDKIM (milter 8891)      │
        │   ├─ Dovecot IMAP 143 (interno)  │◄── buzón rebotes (usuario local)
        │   └─ SASL para submission 587    │
        │                                  │
        │  Docker (red fija 172.20.0.0/24) │
        │   ├─ mautic_web  80 → 127.0.0.1:8080 ── nginx :443 TLS ◄── operador/destinatarios
        │   └─ mysql:8.0   (sin puertos publicados)
        └──────────────────────────────────┘
```

## 2. Componentes y por qué

| Componente | Versión | Despliegue | Motivo |
|---|---|---|---|
| Ubuntu | 24.04 LTS | SO del VPS | Soporte hasta 2029; paquetes estables y homogéneos. |
| Postfix | 3.8.x (paquete Ubuntu) | Nativo | MTA de referencia. **Nativo y no en Docker** porque el correo saliente debe salir con la IP real del VPS (sin NAT de Docker), para que A/PTR/HELO coincidan, y porque la cola, el milter y el arranque son más simples y auditables así. |
| OpenDKIM | 2.11 (paquete Ubuntu) | Nativo | Firma DKIM vía milter. Mantenido por la distro y compatible con Postfix. (Alternativa moderna: Rspamd, que además filtra; se descarta por simplicidad — ver §6.) |
| Dovecot | 2.3.x (core+imapd) | Nativo | Dos funciones mínimas: IMAP **interno** del buzón de rebotes y SASL para submission 587. No hay buzones de usuario, no hay POP3, no hay exposición pública. |
| Mautic | 7.2.1 (imagen oficial `mautic/mautic:7.2.1-apache`) | Docker Compose | Gestión de campañas, contactos, segmentos, bajas y automatización. **En Docker** porque es una aplicación PHP pesada cuyo ciclo de actualizaciones se simplifica con imágenes fijadas (pin por tag) y porque aísla sus dependencias del sistema de correo. Versión verificada en Docker Hub a fecha de este proyecto. |
| MySQL | 8.0 (imagen oficial) | Docker Compose | BD recomendada por Mautic 5–7 (Mautic 7 deprecó versiones EOL). Sin puertos publicados: solo accesible en la red interna de Docker. |
| nginx + certbot | 1.24 / actual | Nativo | TLS del panel y de las páginas de baja. La imagen de Mautic escucha HTTP sin cifrar **solo en 127.0.0.1:8080**; nginx aporta TLS real. |
| ufw | distro | Nativo | Superficie mínima: 22 (idealmente solo desde IPs de administración), 25, 80, 443. |

**Redis: no se despliega por defecto.** Mautic 7 lo usa opcionalmente para cache de conteos de segmentos y locks; con el volumen objetivo (≥1.000/día) no es necesario. `compose.yaml` incluye un bloque comentado para activarlo si el proyecto crece.

## 3. Flujos clave

### 3.1 Envío de una campaña
1. El operador crea la campaña/email en Mautic (UI en `https://FQDN_HOST`).
2. El cron del host ejecuta `mautic:email:send --limit=LOTE` cada 5 minutos: control **explícito y pausable** del ritmo (comentar una línea de cron detiene el envío).
3. Mautic abre sesión SMTP contra `host.docker.internal:25` (= gateway de la red Docker, 172.20.0.1, el host). Postfix permite el relay porque `mynetworks` incluye `172.20.0.0/24` y **solo** esa red además de loopback.
4. El `MAIL FROM` (envelope sender) es `devolucion@DOMINIO` (configurable en correo.env); el `From:` visible es el remitente de la campaña (`*@DOMINIO`).
5. Postfix pasa cada mensaje por el milter OpenDKIM (firma `relaxed/simple`, 2048 bits) y lo entrega con TLS oportunista. Si OpenDKIM cae, `milter_default_action=tempfail` **retrasa** el envío en lugar de mandar correo sin firmar.
6. Los límites anti-fuga de ritmo operan en dos capas: lote de Mautic (cron) y válvulas por cliente en Postfix (`smtpd_client_message_rate_limit` — Mautic está sujeto a ellas porque las excepciones solo incluyen loopback —, `default_destination_rate_delay`, concurrencias limitadas).

### 3.2 Recepción y procesado de rebotes
1. Un DSN de un servidor remoto llega por SMTP:25 al envelope sender `devolucion@DOMINIO`.
2. Postfix lo entrega en el Maildir del usuario local `rebotes` (alias en `/etc/aliases`). No hay buzones de usuario ni correo personal: solo este buzón técnico.
3. Cada 10 minutos, `mautic:monitored_email` lee ese buzón por **IMAP interno** (Mautic → `host.docker.internal:143`, Dovecot escucha solo en `127.0.0.1` y `172.20.0.1`).
4. Mautic clasifica hard/soft bounces, marca el contacto (Do Not Contact en permanentes) y borra el mensaje procesado. Los soft bounces acumulados también generan exclusión según la política configurada en la UI de Mautic.

### 3.3 Bajas
- Enlace en el pie de cada email (`{unsubscribe_url}`) → página de Mautic vía nginx HTTPS.
- Mautic ≥5.0 emite cabeceras **List-Unsubscribe / List-Unsubscribe-Post (RFC 8058)** para baja en un clic. Verificación incluida en `docs/07-pruebas.md`.
- Los DSN con tipo `list-unsubscribe` en el buzón también se procesan por Monitored Email.

## 4. Red, puertos y firewall

| Puerto | Escucha | Expuesto a Internet | Uso |
|---|---|---|---|
| 22/tcp | sshd | Solo desde `IPS_ADMIN_UFW` (si se define) | Administración |
| 25/tcp | Postfix | Sí (ufw) | Recepción de DSN; salida vía conexión saliente |
| 80/tcp | nginx | Sí | ACME + redirección a HTTPS |
| 443/tcp | nginx | Sí | Panel Mautic y páginas de baja |
| 587/tcp | Postfix submission | Opcional (no abierto por defecto) | Envío autenticado del operador (TLS+SASL obligatorios) |
| 143/tcp | Dovecot | **No** (loopback + gateway Docker) | Lectura del buzón de rebotes por Mautic |
| 3306 | MySQL | **No** (solo red interna Docker) | BD de Mautic |
| 8080 | mautic_web | **No** (127.0.0.1) | Proxy interno de nginx |
| 8891 | OpenDKIM | **No** (127.0.0.1) | Milter de Postfix |

**Gotcha importante Docker+ufw:** los puertos publicados por Docker **evitan ufw**. Por eso ninguna publicación de `compose.yaml` se hace en 0.0.0.0: solo `127.0.0.1:8080`. Si añades publicaciones, hazlo siempre en loopback o detrás de nginx.

## 5. Decisión: ¿Docker Compose o nativo? (justificación)

- **Postfix/OpenDKIM/Dovecot nativos:** el MTA es la pieza crítica de entregabilidad. Nativo elimina NAT de Docker sobre el tráfico SMTP (la IP de origen debe ser la del VPS), simplifica el chroot/SASL de Postfix↔Dovecot, y deja la cola y los logs en el sistema estándar (`postqueue`, `/var/log/mail.log`).
- **Mautic + MySQL en Docker:** son aplicaciones de negocio con ciclos de actualización propios. El pin de imagen (`7.2.1-apache`) hace la actualización reversible (cambiar tag + `up -d`) y el rollback documentado. `restart: unless-stopped` + healthcheck de BD.
- **Un solo host al inicio:** menor coste y superficie. La separación promocional/transaccional y el escalado (segundo VPS con su propia IP y reputación) están descritos en `docs/06-operacion.md` y `docs/04-entregabilidad.md`.

## 6. Alternativas consideradas y descartadas

| Alternativa | Por qué se descarta |
|---|---|
| Todo nativo (Mautic con apt/PHP manual) | Gestión de dependencias PHP frágil y actualizaciones dolorosas; Docker aporta reversibilidad. |
| Todo en Docker (también Postfix) | NAT y colas dentro de contenedores, milter y chroot más complejos; el MTA es más seguro y auditable en el host. |
| Rspamd como firmante/filtro | Potente pero introduce una plataforma nueva que excede el alcance; OpenDKIM es el estándar de paquete de distro para firmar. Re-evaluable al escalar. |
| Reenvío de rebotes a un correo externo (Gmail etc.) | Depende de terceros, rompe el flujo automático y añade latencia al procesado de bounces. |
| APIs comerciales como fallback | Prohibido por los requisitos del proyecto (arquitectura 100% SMTP propio). |

## 7. Límites conocidos del diseño

- Un solo VPS = una sola reputación. El correo transaccional de otros sistemas NO debe salir por aquí si es crítico (o debe separarse cuando el proyecto lo requiera: segunda IP/segundo Postfix).
- La entrega al buzón o a spam **no está garantizada por ninguna configuración**: se mide con el plan de `docs/04-entregabilidad.md`.
- Si el proveedor bloquea el puerto 25 saliente, **no hay plan B con APIs**: el despliegue se detiene (ver `docs/08-resolucion-problemas.md`).

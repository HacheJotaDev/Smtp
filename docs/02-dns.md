# 02 — DNS, SPF, DKIM, DMARC, PTR y TLS

> Regla del proyecto: **no se publican valores de ejemplo como si fueran reales**.
> Usa `dns/registros-dns.plantilla.md` como tabla de trabajo y
> `scripts/mostrar-dns.sh` para imprimir tus valores exactos una vez rellenado
> `correo.env` y generada la clave DKIM.

## 1. Registros obligatorios (resumen)

| Registro | Nombre | Contenido | Nota clave |
|---|---|---|---|
| A | `mail.DOMINIO` | IP pública del VPS | Debe coincidir con PTR y con `myhostname` |
| PTR | (panel del proveedor) | `mail.DOMINIO` | Lo configura el **proveedor del VPS**, no tu DNS |
| MX | `DOMINIO` | `10 mail.DOMINIO` | Necesario para recibir DSN/rebotes |
| TXT (SPF) | `DOMINIO` | `v=spf1 a mx ip4:IP -all` | **Un único** registro SPF por dominio |
| TXT (DKIM) | `SELECTOR._domainkey.DOMINIO` | clave pública 2048 | Se imprime con `mostrar-dns.sh` tras `30-dkim.sh` |
| TXT (DMARC) | `_dmarc.DOMINIO` | `v=DMARC1; p=none; rua=mailto:POSTMASTER; ...` | Empieza en `p=none` (observación) |

### Errores típicos de SPF
- Publicar **dos** registros TXT que empiezan por `v=spf1`: inválido. Fusiónalos en uno.
- Olvidar un emisor legítimo (p. ej. el proveedor de facturación que también envía con tu dominio) o incluir uno muerto. Revisa quién envía con tu dominio **antes** de fijar la política.
- Usar `+all` o `~all` con emisores desconocidos: amplía la superficie de spoofing. Este proyecto usa `-all` cuando la lista de emisores está cerrada.

### DMARC: observación antes de endurecer
1. Publica `p=none` con `rua` y **revisa los informes semanalmente** 2–4 semanas.
2. Confirma que SPF y DKIM pasan con alineación (dominio visible `From` = `DOMINIO`).
3. Sube progresivamente: `p=none` → `p=quarantine; pct=25` → `pct=100` → `p=reject`.
   Solo endurece cuando los informes no muestren fuentes legítimas fallando.

## 2. Coherencia HELO / A / PTR (obligatoria)

Postfix se anuncia como `$myhostname = FQDN_HOST`. Muchos receptores (Gmail, Outlook) comprueban:

```
HELO/EHLO == FQDN_HOST == PTR(IP) == A(FQDN_HOST) == IP real
```

Si el proveedor no te permite fijar el PTR, **no continúes con envío de campañas**: la probabilidad de rechazo es muy alta. Solicita el cambio al soporte del proveedor; es un servicio estándar en Hetzner, OVH, DigitalOcean, Linode y similares (cada uno con su panel/procedimiento).

Verificación:

```bash
dig +short A mail.tudominio.example        # → tu IP
dig +short -x TU_IP                        # → mail.tudominio.example
postconf myhostname                        # → mail.tudominio.example
```

## 3. Certificados TLS

- `certbot` obtiene un certificado para `FQDN_HOST` (script `60-nginx-tls.sh`) que sirve para nginx **y** para Postfix/Dovecot (las rutas están en la plantilla de `main.cf`).
- El hook `/etc/letsencrypt/renewal-hooks/deploy/recargar-correo.sh` recarga los tres servicios al renovar.
- Comprobación:

```bash
openssl s_client -starttls smtp -connect mail.tudominio.example:25 -brief
openssl x509 -enddate -noout -in /etc/letsencrypt/live/mail.tudominio.example/fullchain.pem
certbot renew --dry-run
```

## 4. IPv6

Se desactiva en Postfix al inicio (`inet_protocols = ipv4`) **a propósito**: publicar AAAA sin PTR v6, SPF `ip6:` y pruebas equivale a tener dos reputaciones a medias. Para habilitarlo más adelante:

1. PTR v6 en el proveedor + AAAA en la zona.
2. Añade `ip6:DIR_V6` al SPF.
3. Cambia a `inet_protocols = all` y re-verifica con `80-verificar.sh`.

## 5. DNSSEC y MTA-STS/TLS-RPT (opcionales, recomendables después)

- **DNSSEC**: actívalo en el registrador (firma de zona + DS en el TLD). Verifica el flag `ad` con `dig +dnssec`. Hazlo con la zona estable, no el día del primer envío.
- **TLS-RPT**: TXT en `_smtp._tls.DOMINIO` = `v=TLSRPTv1; rua=mailto:POSTMASTER`.
- **MTA-STS**: TXT `mta-sts.DOMINIO` = `v=STSv1; id=AAAAMMDD` + fichero publicado en `https://mta-sts.DOMINIO/.well-known/mta-sts.txt`. Requiere vhost adicional; considera solo cuando el sistema sea estable.

## 6. Listas de comprobación finales de DNS

```bash
# Directo e inverso
dig +short A mail.tudominio.example
dig +short -x TU_IP

# Autenticación
dig +short TXT tudominio.example                 # SPF
dig +short TXT mta1._domainkey.tudominio.example # DKIM
dig +short TXT _dmarc.tudominio.example          # DMARC
dig +short MX tudominio.example

# Validadores externos (solo lectura, sin enviar nada)
#   https://mxtoolbox.com/spf.aspx   https://mxtoolbox.com/dmarc.aspx
#   https://dmarcian.com/dmarc-inspector/
```

## 7. Tabla de valores que DEBES sustituir

| Símbolo | Dónde se usa | Ejemplo de formato (no es un valor real) |
|---|---|---|
| `DOMINIO` | correo.env, DNS, Mautic | `tudominio.example` |
| `FQDN_HOST` | correo.env, PTR, certificado | `mail.tudominio.example` |
| `IP_SERVIDOR` | correo.env, A, SPF `ip4:` | `203.0.113.10` (documentación RFC 5737) |
| `SELECTOR_DKIM` | correo.env, DKIM TXT | `mta1` |
| `POSTMASTER` | correo.env, DMARC `rua`, certbot | `postmaster@tudominio.example` |

Nunca uses dominios de terceros, dominios inventados "porque sí" ni IPs que no sean las reales del VPS: la entregabilidad se construye sobre coherencia verificable.

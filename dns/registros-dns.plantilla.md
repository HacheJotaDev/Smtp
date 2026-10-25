# Plantilla de registros DNS a publicar

> **IMPORTANTE:** este archivo es una PLANTILLA de trabajo. Ningún valor de
> este repositorio es real. Sustituye cada `__RELLENAR__` con tus datos reales
> en tu panel de DNS, y guarda la versión rellenada FUERA del repositorio
> (contiene tu infraestructura). Tras generarse la clave DKIM,
> `scripts/mostrar-dns.sh` imprime los valores exactos que debe contener el
> registro TXT de DKIM (la clave pública es pública; la privada nunca sale).

## Tabla de registros

| # | Tipo | Nombre / Host | Valor (sustituir) | TTL | Propósito | Cómo verificar |
|---|------|---------------|-------------------|-----|-----------|----------------|
| 1 | A | `__RELLENAR_FQDN_HOST__` (ej. `mail.ejemplo.com`) | `__RELLENAR_IP_SERVIDOR__` | 3600 | Host de correo y panel Mautic. DEBE coincidir con PTR | `dig +short A mail.ejemplo.com` |
| 2 | PTR | (lo configura el **proveedor del VPS**) | `__RELLENAR_FQDN_HOST__` | - | DNS inverso; si no coincide con HELO, muchos receptores rechazan | `dig +short -x __RELLENAR_IP_SERVIDOR__` |
| 3 | MX | `__RELLENAR_DOMINIO__` (ej. `ejemplo.com`) | `10 __RELLENAR_FQDN_HOST__` | 3600 | Recepción de rebotes (DSN) y correo del dominio | `dig +short MX ejemplo.com` |
| 4 | TXT | `__RELLENAR_DOMINIO__` | `v=spf1 a mx ip4:__RELLENAR_IP_SERVIDOR__ -all` | 3600 | SPF: únicos emisores legítimos. Si usas otros emisores, añádelos (nunca dos registros SPF: se fusionan en uno) | `dig +short TXT ejemplo.com` |
| 5 | TXT | `__RELLENAR_SELECTOR__._domainkey.__RELLENAR_DOMINIO__` | (valor impreso por `scripts/mostrar-dns.sh` tras generar la clave) | 3600 | Clave pública DKIM 2048 bits | `dig +short TXT mta1._domainkey.ejemplo.com` |
| 6 | TXT | `_dmarc.__RELLENAR_DOMINIO__` | `v=DMARC1; p=none; rua=mailto:__RELLENAR_POSTMASTER__; adkim=r; aspf=r; fo=1` | 3600 | DMARC en **modo observación**. Endurecer (quarantine/reject) SOLO tras semanas de informes limpios | `dig +short TXT _dmarc.ejemplo.com` |
| 7 | A | `__RELLENAR_FQDN_HOST__` (mismo host) | (ya cubierto por #1) | 3600 | Panel Mautic / páginas de baja en HTTPS | `curl -I https://mail.ejemplo.com` |

## Registros OPCIONALES (recomendados una vez estable)

| Tipo | Nombre | Valor | Propósito |
|------|--------|-------|-----------|
| TXT | `_smtp._tls.__RELLENAR_DOMINIO__` | `v=TLSRPTv1; rua=mailto:__RELLENAR_POSTMASTER__` | Informes TLS de receptores grandes |
| CNAME | `mta-sts.__RELLENAR_DOMINIO__` | `__RELLENAR_FQDN_HOST__` | MTA-STS (requiere además fichero en `https://mta-sts.dominio/.well-known/mta-sts.txt`) |
| TXT | `mta-sts.__RELLENAR_DOMINIO__` | `v=STSv1; id=__FECHA__` | MTA-STS |
| CAA | `__RELLENAR_DOMINIO__` | `0 issue "letsencrypt.org"` | Restringe entidades emisoras de certificados |

## Comprobaciones de diagnóstico (tras publicar, espera la propagación)

```bash
# Directo
dig +short A __RELLENAR_FQDN_HOST__              # debe devolver tu IP
# Inverso (PTR) — se configura en el panel del PROVEEDOR del VPS
dig +short -x __RELLENAR_IP_SERVIDOR__           # debe devolver tu FQDN
# SPF, DKIM, DMARC
dig +short TXT __RELLENAR_DOMINIO__
dig +short TXT __RELLENAR_SELECTOR__._domainkey.__RELLENAR_DOMINIO__
dig +short TXT _dmarc.__RELLENAR_DOMINIO__
# MX
dig +short MX __RELLENAR_DOMINIO__
# DNSSEC de la zona (si tu registrador lo soporta; opcional pero recomendable)
dig +dnssec __RELLENAR_DOMINIO__ SOA
```

## Coherencia obligatoria (la causa nº1 de rechazos)

- `A` del host == IP pública real del VPS.
- `PTR` (proveedor) == `FQDN_HOST` == `myhostname` de Postfix (HELO/EHLO).
- SPF contiene la IP emisora (y solo emisores legítimos).
- DKIM firmado con el selector publicado y alineado con `DOMINIO` (remitente `From` en ese dominio).
- DMARC: alineación en modo relajado (`r`) con SPF **o** DKIM.

## IPv6

No publiques AAAA hasta que: (1) el proveedor dé PTR para la IPv6,
(2) SPF contenga `ip6:` y (3) Postfix use `inet_protocols = all`.
Publicar AAAA sin ese conjunto causa entregas a medias y fallos difíciles de diagnosticar.

## DNSSEC

Si tu registrador permite DNSSEC: actívalo en la zona y publica el DS en el TLD.
Verifica con `dig +dnssec` (flag `ad`). No actives DNSSEC el mismo día del
primer envío masivo: deja que la zona esté estable primero.

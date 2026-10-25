#!/usr/bin/env python3
# =====================================================================
# validar-csv.py — validación de CSV de contactos ANTES de importarlos
# a Mautic. Solo lectura: no modifica ni envía nada.
#
# Uso:
#   python3 scripts/validar-csv.py contactos.csv [--estricto]
#
# Comprobaciones:
#   - UTF-8 válido y CSV bien formado (comillas, columnas consistentes)
#   - Columna 'email' obligatoria; sintaxis de dirección (RFC simplificado)
#   - Duplicados (exactos y normalizados en minúsculas)
#   - Columnas de consentimiento recomendadas: fuente, fecha_consentimiento
#   - Sin cabeceras inyectables (campos con saltos de línea sospechosos)
#
# Códigos de salida: 0 = válido; 1 = problemas; 2 = uso incorrecto.
# =====================================================================
import csv
import re
import sys
from collections import Counter

EMAIL_RE = re.compile(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
)
OBLIGATORIA = {"email"}
RECOMENDADAS = {"fuente", "fecha_consentimiento"}
FILAS_MUESTRA = 10


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    ruta = sys.argv[1]
    estricto = "--estricto" in sys.argv[2:]

    try:
        # utf-8-sig tolera BOM de Excel
        with open(ruta, newline="", encoding="utf-8-sig") as fh:
            lector = csv.reader(fh)
            filas = list(lector)
    except UnicodeDecodeError as e:
        print(f"[FALLO] El archivo no es UTF-8 válido: {e}")
        return 1
    except csv.Error as e:
        print(f"[FALLO] CSV malformado: {e}")
        return 1

    if not filas:
        print("[FALLO] El CSV está vacío.")
        return 1

    cabecera = [c.strip().lower() for c in filas[0]]
    print(f"[INFO] Columnas detectadas: {cabecera}")

    faltan_oblig = OBLIGATORIA - set(cabecera)
    if faltan_oblig:
        print(f"[FALLO] Faltan columnas obligatorias: {sorted(faltan_oblig)}")
        return 1
    faltan_reco = RECOMENDADAS - set(cabecera)
    if faltan_reco:
        print(f"[AVISO] Faltan columnas recomendadas de consentimiento: {sorted(faltan_reco)}")
        print("        Para compliance, cada contacto debe tener fuente y fecha/evidencia de consentimiento.")

    idx = {c: i for i, c in enumerate(cabecera)}
    total = 0
    validos = 0
    invalidos: list[str] = []
    duplicados: list[str] = []
    sospechosos: list[int] = []

    vistos = Counter()
    for n_linea, fila in enumerate(filas[1:], start=2):
        if not fila or all(not c.strip() for c in fila):
            continue  # línea en blanco: se ignora
        total += 1
        # Columnas inconsistentes
        if len(fila) != len(cabecera):
            sospechosos.append(n_linea)
            continue
        email = fila[idx["email"]].strip().strip("<>").lower()
        # Protección anti-inyección: saltos de línea dentro de campos
        if any("\n" in c or "\r" in c for c in fila):
            sospechosos.append(n_linea)
            continue
        if not EMAIL_RE.match(email) or len(email) > 254:
            invalidos.append(f"línea {n_linea}: {email[:60]!r}")
            continue
        vistos[email] += 1
        validos += 1

    duplicados = [e for e, n in vistos.items() if n > 1]

    print(f"[INFO] Filas de datos: {total}")
    print(f"[OK]   Emails sintácticamente válidos: {validos}")
    if invalidos:
        print(f"[FALLO] Emails inválidos: {len(invalidos)} (muestra: {invalidos[:FILAS_MUESTRA]})")
    if duplicados:
        print(f"[AVISO] Duplicados (se conservará 1 al importar): {len(duplicados)} (muestra: {duplicados[:FILAS_MUESTRA]})")
    if sospechosos:
        print(f"[FALLO] Filas con estructura anómala/posible inyección: {len(sospechosos)} (líneas {sospechosos[:FILAS_MUESTRA]})")

    problemas = len(invalidos) + len(sospechosos)
    if problemas == 0:
        print("[OK] CSV listo para importar en Mautic (revisa también la fuente del consentimiento).")
        return 0
    if estricto:
        print("[FALLO] Modo --estricto: hay problemas; corrige el CSV antes de importar.")
        return 1
    print("[AVISO] Hay problemas; Mautic descartará filas inválidas, pero es mejor corregir antes.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
